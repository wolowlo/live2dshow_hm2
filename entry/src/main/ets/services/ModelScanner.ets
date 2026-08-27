import { fileIo as fs } from '@kit.CoreFileKit';
import { ModelRecord } from './ModelRecord';
import { modelStore } from './ModelStore';
import { resolveCharName } from './CharData';
import { cleanJsonText, parseJsonLenient } from './JsonUtil';
import { parseMocCanvasSize } from './MocParser';
import { Logger } from '../common/Logger';
import { FileUtil } from '../common/FileUtil';

const TAG = 'ModelScanner';

/** model3.json 元数据（显示名 + 动作列表） */
export interface Model3Meta {
  name: string;
  actions: string[];
}

/** 扫描结果汇总 */
export interface ScanResult {
  /** 本次新增入库数量 */
  added: number;
  /** 扫描发现的总模型数（Cubism 2 按入口计） */
  total: number;
}

/**
 * 模型扫描：遍历沙箱模型目录，识别 Cubism 2 / Cubism 3 入口并增量写库。
 * 规则移植自原项目 services.py：
 * - Cubism 3：任意深度 *.model3.json，group = 角色目录的父目录名，path = group/role
 * - Cubism 2：目录内含 `"model": "xxx.moc"` 字段的 json 视为入口（model.json/index.json 等任意命名）
 */
export class ModelScanner {
  private modelsDir: string = '';

  init(modelsDir: string): void {
    this.modelsDir = modelsDir;
  }

  async scanAndPersist(): Promise<ScanResult> {
    // 先修复 C2 入口 json（textures 为空/对象格式、moc 引用失效等），再扫描入库
    const repaired = await this.repairCubism2Entries();
    if (repaired > 0) {
      Logger.info(TAG, 'C2 入口修复完成: %{public}d 个', repaired);
    }
    // C3 入口同样先修复（标准入口缺失 / 贴图引用为空 → 引擎加载无贴图，白板），再扫描入库
    const c3Repaired = await this.repairCubism3Entries();
    if (c3Repaired > 0) {
      Logger.info(TAG, 'C3 入口修复完成: %{public}d 个', c3Repaired);
    }
    const c3Records = await this.scanCubism3();
    const c2Records = await this.scanCubism2();
    let added = 0;
    const all = c3Records.concat(c2Records);
    for (const record of all) {
      const exists = await modelStore.hasRecord(record.version, record.entryPath);
      if (!exists) {
        await modelStore.addModel(record);
        added++;
      } else {
        // 旧记录/旧版本升级：同步显示名与动作列表（收藏/坏/分类等用户状态保留）
        await modelStore.updateModelMeta(record);
      }
    }
    Logger.info(TAG, '扫描完成: 发现 %{public}d 个模型，新增 %{public}d 条记录', all.length, added);
    return { added, total: all.length };
  }

  /**
   * 修复 Cubism 2 入口 json（移植自原项目 import_service._repair_cubism2_refs）：
   * - textures 为空数组/对象格式/引用失效 → 从磁盘补全（textures/ 或根目录 *.png）
   * - model 指向的 .moc 不存在 → 回退目录内实际存在的 .moc
   * 魂器学院等解包模型常把 model.json 精简成 "textures": []，不修复会渲染成白板。
   * 返回修复的 json 文件数。
   */
  private async repairCubism2Entries(): Promise<number> {
    const root = `${this.modelsDir}/cubism2/model`;
    if (!fs.accessSync(root)) {
      return 0;
    }
    const dirs = FileUtil.listDirsRecursive(root);
    let fixed = 0;
    for (const dir of dirs) {
      for (const name of fs.listFileSync(dir)) {
        if (!name.endsWith('.json')) {
          continue;
        }
        const full = `${dir}/${name}`;
        if (!(await this.isCubism2Entry(full))) {
          continue;
        }
        if (await this.repairEntryJson(full, dir)) {
          fixed++;
        }
      }
    }
    return fixed;
  }

  /** 修复单个 C2 入口 json，返回是否发生修改 */
  private async repairEntryJson(jsonPath: string, modelDir: string): Promise<boolean> {
    try {
      const text = await fs.readText(jsonPath);
      const parsed = parseJsonLenient(text);
      if (parsed === null) {
        return false;
      }
      const data = parsed as Record<string, Object>;
      let changed = false;
      // JS 风格尾随逗号 → 重写为标准 JSON（C2 引擎严格 JSON.parse，否则渲染白板）
      if (cleanJsonText(text) !== text) {
        changed = true;
      }

      // model 字段以 / 开头 → 相对化（解包工具常见绝对路径写法）
      const model = data['model'] as string | undefined;
      if (typeof model === 'string' && model.startsWith('/')) {
        data['model'] = model.replace(/^\/+/, '');
        changed = true;
      }
      // model 指向的 .moc 不存在 → 回退目录内首个实际存在的 .moc
      const modelRef = data['model'] as string | undefined;
      if (typeof modelRef === 'string' && modelRef !== '') {
        const modelPath = `${modelDir}/${modelRef}`;
        if (!fs.accessSync(modelPath)) {
          const mocs = fs.listFileSync(modelDir).filter((n: string) => n.endsWith('.moc'));
          if (mocs.length > 0) {
            data['model'] = mocs[0];
            changed = true;
          }
        }
      }

      // textures 补全：对象格式扁平化、空数组/失效引用从磁盘收集
      if (this.fillTextures(data, modelDir)) {
        changed = true;
      }
      // 贴图文件名去空格（如 texture_00 .png → texture_00.png）并同步 JSON 引用：
      // 带空格文件名在 Web 引擎 URL 解析/资源拦截下易加载失败，导入扫描时一次性规范化
      if (await this.normalizeTextureFilenames(data, modelDir)) {
        changed = true;
      }

      // 动作引用修复：失效时在 motions/mtn/textures/moc/physics/json 子目录找同名文件
      const motions = data['motions'] as Record<string, Object> | undefined;
      if (motions) {
        for (const group of Object.keys(motions)) {
          const items = motions[group] as Object[] | undefined;
          if (!items) {
            continue;
          }
          for (const item of items) {
            const entry = item as Record<string, Object>;
            const file = entry['file'] as string | undefined;
            if (typeof file === 'string' && file !== '') {
              const fixed = this.fixRef(file, modelDir);
              if (fixed !== file) {
                entry['file'] = fixed;
                changed = true;
              }
            }
            // 声音引用指向的文件缺失 → 移除该字段（避免引擎播放 404 报错）
            const sound = entry['sound'] as string | undefined;
            if (typeof sound === 'string' && sound !== '') {
              const fixedSound = this.fixRef(sound, modelDir);
              if (!fs.accessSync(`${modelDir}/${fixedSound}`)) {
                // ArkTS 不支持 delete：重建对象移除 sound 字段
                const cleaned: Record<string, Object> = {};
                for (const k of Object.keys(entry)) {
                  if (k !== 'sound') {
                    cleaned[k] = entry[k];
                  }
                }
                items[items.indexOf(item)] = cleaned;
                changed = true;
              } else if (fixedSound !== sound) {
                entry['sound'] = fixedSound;
                changed = true;
              }
            }
          }
        }
      }
      // physics / pose 引用修复
      for (const key of ['physics', 'pose']) {
        const ref = data[key] as string | undefined;
        if (typeof ref === 'string' && ref !== '') {
          const fixed = this.fixRef(ref, modelDir);
          if (fixed !== ref) {
            data[key] = fixed;
            changed = true;
          }
        }
      }

      if (!changed) {
        return false;
      }
      const file = fs.openSync(jsonPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(data, null, 2));
      fs.closeSync(file);
      return true;
    } catch (e) {
      Logger.warn(TAG, 'C2 入口修复失败: %{public}s, err=%{public}s', jsonPath, JSON.stringify(e));
      return false;
    }
  }

  /** 失效相对引用修复：文件不存在时在常见子目录找同名文件，找不到原样返回 */
  private fixRef(ref: string, modelDir: string): string {
    if (ref === '' || ref.startsWith('/')) {
      return ref;
    }
    if (fs.accessSync(`${modelDir}/${ref}`)) {
      return ref;
    }
    const base = ref.substring(ref.lastIndexOf('/') + 1);
    const subDirs = ['motions', 'mtn', 'textures', 'moc', 'physics', 'json'];
    for (const sub of subDirs) {
      const cand = `${modelDir}/${sub}/${base}`;
      if (fs.accessSync(cand)) {
        return `${sub}/${base}`;
      }
    }
    return ref;
  }

  /**
   * 修复 Cubism 3 入口 json（对齐 C2 修复思路）：
   * 解包模型常把完整贴图引用放在隐藏的 .model3.json 或 __data_*.model3.json，
   * 标准 <目录名>.model3.json 缺失或 Textures 为空 → 引擎按目录名加载入口时无贴图（白板）。
   * 这里补全标准入口与贴图引用，并把带空格的贴图文件名规范化。
   * 返回修复的角色目录数。
   */
  private async repairCubism3Entries(): Promise<number> {
    const root = `${this.modelsDir}/cubism3`;
    if (!fs.accessSync(root)) {
      return 0;
    }
    const roleDirs = this.listC3RoleDirs(root);
    let fixed = 0;
    for (const dir of roleDirs) {
      if (await this.repairC3RoleDir(dir)) {
        fixed++;
      }
    }
    return fixed;
  }

  /** 找出所有 C3 角色目录：目录内含 *.model3.json 或 *.moc3 即视为角色目录（兼容只有隐藏入口的目录） */
  private listC3RoleDirs(root: string): string[] {
    const out: string[] = [];
    this.collectC3RoleDirs(root, out);
    return out;
  }

  /** 递归收集 C3 角色目录（角色目录内部不再下钻，textures/motions 等子目录除外） */
  private collectC3RoleDirs(dir: string, out: string[]): void {
    let hasModel = false;
    try {
      for (const name of fs.listFileSync(dir)) {
        if (name.endsWith('.model3.json') || name.endsWith('.moc3')) {
          hasModel = true;
          break;
        }
      }
    } catch (e) {
      return;
    }
    if (hasModel) {
      out.push(dir);
      return;
    }
    try {
      for (const name of fs.listFileSync(dir)) {
        if (fs.statSync(`${dir}/${name}`).isDirectory()) {
          this.collectC3RoleDirs(`${dir}/${name}`, out);
        }
      }
    } catch (e) {
      // 忽略不可读目录
    }
  }

  /** 修复单个 C3 角色目录：保证 <目录名>.model3.json 存在且贴图引用有效，返回是否发生修改 */
  private async repairC3RoleDir(dir: string): Promise<boolean> {
    try {
      const roleName = FileUtil.basename(dir);
      const expected = `${dir}/${roleName}.model3.json`;
      const hasExpected = fs.accessSync(expected);
      const candidates = fs.listFileSync(dir).filter((n: string) => n.endsWith('.model3.json'));
      if (candidates.length === 0) {
        return false;
      }
      // 基座入口：标准入口存在则用它；否则优先 __data_*（结构与标准一致且带 Motions）
      let baseName = '';
      if (hasExpected && candidates.indexOf(`${roleName}.model3.json`) >= 0) {
        baseName = `${roleName}.model3.json`;
      } else {
        baseName = candidates.find((n: string) => n.startsWith('__data_')) ?? candidates[0];
      }
      const base = await this.readC3Json(`${dir}/${baseName}`);
      if (base === null) {
        return false;
      }
      const fr = base['FileReferences'] as Record<string, Object> | undefined;
      if (!fr) {
        return false;
      }
      let changed = !hasExpected;
      // 1) 贴图引用补全：为空/失效时从隐藏 .model3.json 借用，再兜底从磁盘收集
      if (await this.fillC3Textures(base, dir)) {
        changed = true;
      }
      // 2) 带空格贴图文件名规范化（去空格重命名 + 同步引用）
      if (await this.normalizeC3TextureFilenames(base, dir)) {
        changed = true;
      }
      if (!changed) {
        return false;
      }
      // 3) 标准入口缺失时写入 <目录名>.model3.json（内容 = 基座 + 已修复的引用）
      await this.writeC3Json(expected, base);
      return true;
    } catch (e) {
      Logger.warn(TAG, 'C3 入口修复失败: %{public}s, err=%{public}s', dir, JSON.stringify(e));
      return false;
    }
  }

  /** 补全 C3 入口的 Textures：已有有效引用则只过滤失效项；空/全失效时优先借用隐藏 .model3.json，再兜底扫描磁盘 */
  private async fillC3Textures(base: Record<string, Object>, dir: string): Promise<boolean> {
    const fr = base['FileReferences'] as Record<string, Object>;
    const tex = fr['Textures'];
    const list = Array.isArray(tex) ? tex as string[] : [];
    // 已有有效引用 → 仅保留有效项
    const valid: string[] = [];
    for (const item of list) {
      if (typeof item === 'string' && item !== '' && fs.accessSync(`${dir}/${item}`)) {
        valid.push(item);
      }
    }
    if (valid.length > 0) {
      if (valid.length === list.length) {
        return false;
      }
      fr['Textures'] = valid;
      return true;
    }
    // 借用隐藏 .model3.json 的贴图引用（解包模型把完整贴图引用放在这里）
    const hiddenPath = `${dir}/.model3.json`;
    if (fs.accessSync(hiddenPath)) {
      const hidden = await this.readC3Json(hiddenPath);
      const hiddenFr = hidden ? hidden['FileReferences'] as Record<string, Object> : undefined;
      const hiddenTex = hiddenFr ? hiddenFr['Textures'] as Object[] : undefined;
      if (Array.isArray(hiddenTex)) {
        const borrowed: string[] = [];
        for (const item of hiddenTex) {
          if (typeof item === 'string' && item !== '' && fs.accessSync(`${dir}/${item}`)) {
            borrowed.push(item);
          }
        }
        if (borrowed.length > 0) {
          fr['Textures'] = borrowed;
          return true;
        }
      }
    }
    // 兜底：磁盘收集 textures/ 子目录 → 根目录 *.png（c_5021 等裸贴图布局）
    const cands: string[] = [];
    const tdir = `${dir}/textures`;
    if (fs.accessSync(tdir)) {
      for (const n of fs.listFileSync(tdir)) {
        if (n.endsWith('.png') && !n.startsWith('.')) {
          cands.push(`textures/${n}`);
        }
      }
    }
    if (cands.length === 0) {
      for (const n of fs.listFileSync(dir)) {
        if (n.endsWith('.png') && !n.startsWith('.')) {
          cands.push(n);
        }
      }
    }
    if (cands.length > 0) {
      cands.sort((a: string, b: string) => a.localeCompare(b));
      fr['Textures'] = cands;
      return true;
    }
    return false;
  }

  /** 贴图文件名去空格并同步 JSON 引用（带空格文件名在 Web 引擎 URL 解析/资源拦截下易加载失败） */
  private async normalizeC3TextureFilenames(base: Record<string, Object>, dir: string): Promise<boolean> {
    const fr = base['FileReferences'] as Record<string, Object>;
    const tex = fr['Textures'];
    if (!Array.isArray(tex)) {
      return false;
    }
    const list = tex as string[];
    let changed = false;
    for (let i = 0; i < list.length; i++) {
      const item = list[i];
      if (typeof item !== 'string' || item.indexOf(' ') < 0) {
        continue;
      }
      const newName = item.replace(/ /g, '');
      if (newName === '' || newName === item) {
        continue;
      }
      const srcPath = `${dir}/${item}`;
      const destPath = `${dir}/${newName}`;
      // 引用失效但磁盘上已是去空格名：只修正引用
      if (!fs.accessSync(srcPath) && fs.accessSync(destPath)) {
        list[i] = newName;
        changed = true;
        continue;
      }
      // 源文件存在且目标名未被占用：重命名并修正引用
      if (fs.accessSync(srcPath) && !fs.accessSync(destPath)) {
        try {
          await fs.rename(srcPath, destPath);
          list[i] = newName;
          changed = true;
          Logger.info(TAG, 'C3 贴图去空格: %{public}s → %{public}s', item, newName);
        } catch (e) {
          Logger.warn(TAG, 'C3 贴图重命名失败: %{public}s, err=%{public}s', srcPath, JSON.stringify(e));
        }
      }
    }
    return changed;
  }

  /** 容错读取 model3.json（JS 风格尾随逗号容忍），失败返回 null */
  private async readC3Json(path: string): Promise<Record<string, Object> | null> {
    try {
      const text = await fs.readText(path);
      return parseJsonLenient(text) as Record<string, Object> | null;
    } catch (e) {
      return null;
    }
  }

  /** 写入 model3.json（标准 JSON 格式） */
  private async writeC3Json(path: string, data: Record<string, Object>): Promise<void> {
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, JSON.stringify(data, null, 2));
    } finally {
      fs.closeSync(file);
    }
  }

  /** 补全入口 json 的 textures 引用（移植自原项目 _fill_textures），返回是否修改 */
  private fillTextures(data: Record<string, Object>, modelDir: string): boolean {
    let tex = data['textures'];
    if (!Array.isArray(tex)) {
      if (tex instanceof Object && !Array.isArray(tex)) {
        const flat: string[] = [];
        const obj = tex as Record<string, Object>;
        for (const key of Object.keys(obj)) {
          const val = obj[key];
          if (Array.isArray(val)) {
            const items = val as Object[];
            for (const item of items) {
              if (typeof item === 'string') {
                flat.push(item);
              }
            }
          }
        }
        tex = flat;
      } else {
        tex = [];
      }
    }
    const list = tex as string[];
    // 已有有效引用 → 仅过滤失效项
    const valid: string[] = [];
    for (const item of list) {
      if (typeof item === 'string' && item !== '' && fs.accessSync(`${modelDir}/${item}`)) {
        valid.push(item);
      }
    }
    if (valid.length > 0) {
      if (valid.length === list.length) {
        return false;
      }
      data['textures'] = valid;
      return true;
    }
    // 全部失效或为空 → 从磁盘收集：textures/ 子目录 → 数字后缀目录 → 根目录 *.png
    const cands: string[] = [];
    const tdir = `${modelDir}/textures`;
    if (fs.accessSync(tdir)) {
      for (const n of fs.listFileSync(tdir)) {
        if (n.endsWith('.png') && !n.startsWith('.')) {
          cands.push(`textures/${n}`);
        }
      }
    }
    if (cands.length === 0) {
      for (const n of fs.listFileSync(modelDir)) {
        if (n.endsWith('.png') && !n.startsWith('.')) {
          cands.push(n);
        }
      }
    }
    if (cands.length > 0) {
      cands.sort((a: string, b: string) => a.localeCompare(b));
      data['textures'] = cands;
      return true;
    }
    return false;
  }

  /**
   * 贴图文件名去空格并同步 JSON 引用，返回是否发生修改。
   * 目标名已存在时跳过（不覆盖、不改引用），避免同名文件冲突。
   */
  private async normalizeTextureFilenames(data: Record<string, Object>, modelDir: string): Promise<boolean> {
    const tex = data['textures'];
    if (!Array.isArray(tex)) {
      return false;
    }
    const list = tex as string[];
    let changed = false;
    for (let i = 0; i < list.length; i++) {
      const item = list[i];
      if (typeof item !== 'string' || item.indexOf(' ') < 0) {
        continue;
      }
      const newName = item.replace(/ /g, '');
      if (newName === '' || newName === item) {
        continue;
      }
      const srcPath = `${modelDir}/${item}`;
      const destPath = `${modelDir}/${newName}`;
      // 引用失效但磁盘上已是去空格名：只修正引用
      if (!fs.accessSync(srcPath) && fs.accessSync(destPath)) {
        list[i] = newName;
        changed = true;
        continue;
      }
      // 源文件存在且目标名未被占用：重命名并修正引用
      if (fs.accessSync(srcPath) && !fs.accessSync(destPath)) {
        try {
          await fs.rename(srcPath, destPath);
          list[i] = newName;
          changed = true;
          Logger.info(TAG, '贴图去空格: %{public}s → %{public}s', item, newName);
        } catch (e) {
          Logger.warn(TAG, '贴图重命名失败: %{public}s, err=%{public}s', srcPath, JSON.stringify(e));
        }
      }
    }
    return changed;
  }

  private async scanCubism3(): Promise<ModelRecord[]> {
    const result: ModelRecord[] = [];
    const root = `${this.modelsDir}/cubism3`;
    if (!fs.accessSync(root)) {
      return result;
    }
    const entries = FileUtil.listFilesRecursive(root, '.model3.json');
    for (const entryPath of entries) {
      const roleDir = this.parentDir(entryPath);
      const role = FileUtil.basename(roleDir);
      const group = FileUtil.basename(this.parentDir(roleDir));
      const path = `${group}/${role}`;
      const meta = await this.readModel3Meta(`${roleDir}/${role}.model3.json`);
      result.push(new ModelRecord(
        'cubism3',
        group,
        role,
        path,
        this.c3DisplayName(path, role, meta.name),
        '',
        meta.actions,
      ));
    }
    return result;
  }

  /** 读取 model3.json 的显示名（Name）与动作列表（FileReferences.Motions） */
  private async readModel3Meta(path: string): Promise<Model3Meta> {
    try {
      const text = await fs.readText(path);
      const parsed = parseJsonLenient(text);
      if (parsed === null) {
        return { name: '', actions: [] };
      }
      const data = parsed as Record<string, Object>;
      const name = String(data['Name'] ?? '');
      const fileRefs = data['FileReferences'] as Record<string, Object> | undefined;
      const motions = fileRefs ? fileRefs['Motions'] as Record<string, Object[]> : undefined;
      const actions: string[] = [];
      if (motions) {
        for (const group of Object.keys(motions)) {
          const items = motions[group] ?? [];
          for (const item of items) {
            const file = (item as Record<string, Object>)['File'] as string | undefined;
            if (!file) {
              continue;
            }
            // 动作名 = 文件名去扩展名（与引擎 model.motions 的 key 一致）
            const stem = FileUtil.basename(file).replace(/\.(motion3\.json|json)$/i, '');
            if (stem !== '' && actions.indexOf(stem) < 0) {
              actions.push(stem);
            }
          }
        }
      }
      return { name, actions };
    } catch (e) {
      return { name: '', actions: [] };
    }
  }

  /** C3 显示名：charData 映射 → model3.json Name → 角色目录名 */
  private c3DisplayName(path: string, role: string, modelName: string): string {
    const charName = resolveCharName(path, role);
    if (charName !== '') {
      return charName;
    }
    if (modelName !== '') {
      return modelName;
    }
    return role;
  }

  private async scanCubism2(): Promise<ModelRecord[]> {
    const result: ModelRecord[] = [];
    const root = `${this.modelsDir}/cubism2/model`;
    if (!fs.accessSync(root)) {
      return result;
    }
    const dirs = FileUtil.listDirsRecursive(root);
    for (const dir of dirs) {
      const entries = fs.listFileSync(dir);
      const entryJson = entries.filter((name) => name.endsWith('.json'));
      const candidates: string[] = [];
      for (const name of entryJson) {
        const full = `${dir}/${name}`;
        if (!(await this.isCubism2Entry(full))) {
          continue;
        }
        // 包装入口过滤：入口引用的 moc 落在含独立入口的子目录（根 model.json → char_*/res/xx.moc），
        // 说明是冗余包装，由子目录真实入口承担，避免登记出“指向不存在 moc”的坏模型
        if (await this.isWrapperEntry(full, dir)) {
          continue;
        }
        candidates.push(name);
      }
      if (candidates.length === 0) {
        continue;
      }
      // 入口优选：同一目录只登记一个最佳入口（魂器学院等常同时含 model.json 与 Lead_00.model.json）
      const best = await this.pickBestEntry(dir, candidates);
      if (best === '') {
        continue;
      }
      const rel = dir.substring(root.length + 1);
      const group = rel === '' ? FileUtil.basename(dir) : rel;
      const full = `${dir}/${best}`;
      const record = new ModelRecord(
        'cubism2',
        group,
        FileUtil.basename(dir),
        `model/${group}/${best}`,
        // 显示名 = 角色分组相对路径（与原项目 C2 分组一致）；入口文件名作为 outfit 名保留在 roleName
        group,
        '',
        this.c2Actions(dir),
      );
      // 画布尺寸：读取入口 json 的 model 字段定位 .moc 并解析（与原项目 canvas_w/h 一致）
      const mocRel = await this.c2MocRel(full);
      if (mocRel !== '') {
        const size = parseMocCanvasSize(`${dir}/${mocRel}`);
        if (size) {
          record.canvasW = size.width;
          record.canvasH = size.height;
        }
      }
      result.push(record);
    }
    return result;
  }

  /** 判断入口 json 是否为“包装入口”：引用的 moc 在含独立模型入口的子目录中 */
  private async isWrapperEntry(jsonPath: string, modelDir: string): Promise<boolean> {
    try {
      const text = await fs.readText(jsonPath);
      const parsed = parseJsonLenient(text);
      if (parsed === null) {
        return false;
      }
      const data = parsed as Record<string, Object>;
      const ref = data['model'] as string;
      if (typeof ref !== 'string' || ref === '') {
        return false;
      }
      const refPath = `${modelDir}/${ref}`;
      if (fs.accessSync(refPath)) {
        // 引用文件直接存在：本目录真实入口，不是包装
        return false;
      }
      const refDir = refPath.substring(0, refPath.lastIndexOf('/'));
      if (refDir === modelDir || !fs.accessSync(refDir)) {
        return false;
      }
      // 子目录内含独立入口 json 或 .moc → 真实模型在子目录，本入口为包装
      for (const n of fs.listFileSync(refDir)) {
        const child = `${refDir}/${n}`;
        if (n.endsWith('.json') && (await this.isCubism2Entry(child))) {
          return true;
        }
        if (n.endsWith('.moc')) {
          return true;
        }
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /** 从同目录多个 C2 入口中选一个最佳入口：model.json 优先，其次 moc 存在且 textures 非空者 */
  private async pickBestEntry(modelDir: string, candidates: string[]): Promise<string> {
    let validFallback = '';
    for (const name of candidates) {
      const usable = await this.isUsableEntry(`${modelDir}/${name}`, modelDir);
      if (name === 'model.json' && usable) {
        return name;
      }
      if (usable && validFallback === '') {
        validFallback = name;
      }
    }
    // 没有任何入口可用时，退回 model.json（修复流程已尽力补全）
    return validFallback !== '' ? validFallback
      : (candidates.indexOf('model.json') >= 0 ? 'model.json' : candidates[0]);
  }

  /** 入口是否可用：model 引用的 .moc 存在（修复后），且 textures 非空 */
  private async isUsableEntry(jsonPath: string, modelDir: string): Promise<boolean> {
    try {
      const text = await fs.readText(jsonPath);
      const parsed = parseJsonLenient(text);
      if (parsed === null) {
        return false;
      }
      const data = parsed as Record<string, Object>;
      const modelRef = data['model'] as string;
      if (typeof modelRef !== 'string' || modelRef === '') {
        return false;
      }
      if (!fs.accessSync(`${modelDir}/${modelRef}`)) {
        return false;
      }
      const tex = data['textures'];
      return Array.isArray(tex) && tex.length > 0;
    } catch (e) {
      return false;
    }
  }

  /** C2 入口 json 的 .moc 相对路径（model 字段），失败返回空串 */
  private async c2MocRel(path: string): Promise<string> {
    try {
      const text = await fs.readText(path);
      const parsed = parseJsonLenient(text);
      if (parsed === null) {
        return '';
      }
      const data = parsed as Record<string, Object>;
      const model = data['model'] as string;
      return typeof model === 'string' && model.endsWith('.moc') ? model : '';
    } catch (e) {
      return '';
    }
  }

  /** C2 动作列表：扫描模型目录下 motions/*.mtn 与根目录 *.mtn（相对路径，兼容两种布局） */
  private c2Actions(modelDir: string): string[] {
    const names: string[] = [];
    // motions/ 子目录优先（原项目标准布局）
    const motionsDir = `${modelDir}/motions`;
    if (fs.accessSync(motionsDir)) {
      try {
        for (const file of fs.listFileSync(motionsDir)) {
          if (file.endsWith('.mtn')) {
            names.push(`motions/${file}`);
          }
        }
      } catch (e) {
        Logger.warn(TAG, '扫描 C2 动作失败: %{public}s', motionsDir);
      }
    }
    // 根目录 *.mtn（内置示例等旧布局）
    try {
      for (const file of fs.listFileSync(modelDir)) {
        if (file.endsWith('.mtn')) {
          names.push(file);
        }
      }
    } catch (e) {
      Logger.warn(TAG, '扫描 C2 根目录动作失败: %{public}s', modelDir);
    }
    return names.sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()));
  }

  /** 判断 json 是否为 Cubism 2 入口：包含以 .moc 结尾的 model 字段 */
  private async isCubism2Entry(path: string): Promise<boolean> {
    try {
      const text = await fs.readText(path);
      const data = parseJsonLenient(text) as Record<string, Object> | null;
      const model = data ? data['model'] as string : undefined;
      return typeof model === 'string' && model.endsWith('.moc');
    } catch (e) {
      return false;
    }
  }

  private parentDir(path: string): string {
    const idx = path.lastIndexOf('/');
    return idx > 0 ? path.substring(0, idx) : '';
  }
}

/** 模块级单例 */
export const modelScanner: ModelScanner = new ModelScanner();
