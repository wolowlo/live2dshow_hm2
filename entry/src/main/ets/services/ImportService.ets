import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import zlib from '@ohos.zlib';
import resourceManager from '@ohos.resourceManager';
import { parseJsonLenient } from './JsonUtil';
import { modelScanner } from './ModelScanner';
import { thumbnailService } from './ThumbnailService';
import { modelStore } from './ModelStore';
import { ModelRecord } from './ModelRecord';
import { Logger } from '../common/Logger';
import { FileUtil } from '../common/FileUtil';

const TAG = 'ImportService';

/** Cubism 3 导入时跳过的通用容器层（对齐原项目 import_service._GENERIC_CONTAINER_NAMES） */
const C3_GENERIC_CONTAINER_NAMES: string[] = [
  'live2d', 'l2d', 'model', 'models', 'chara', 'character', 'characters',
  'moc', 'data', 'assets', 'textures', 'motions', 'unit', 'units',
  'res', 'resources', 'resource', 'tex', 'texture', 'expressions', 'expression',
];

/** 导入结果汇总 */
export interface ImportResult {
  /** 成功移动的顶层目录/文件数 */
  movedItems: number;
  /** 扫描新增入库数量 */
  added: number;
  /** 识别到的模型版本：cubism2 | cubism3 | mixed | none */
  version: string;
}

/**
 * zip 包导入：Picker URI → 沙箱 → 解压 → 识别版本 → 移动进模型库 → 增量扫描。
 * 模型目录保持解压相对结构，扫描器按原项目规则（rglob）识别入口。
 */
export class ImportService {
  /** 导入内置示例模型（rawfile → 沙箱 → 扫描）：遍历 rawfile/models 下任意目录，不限于固定路径 */
  async importSamples(context: common.UIAbilityContext, category: string = ''): Promise<ImportResult> {
    const resMgr = context.resourceManager;
    const modelsRoot = `${context.filesDir}/models`;
    const beforeKeys = await this.collectEntryKeys();
    let moved = 0;
    // Cubism 3：递归扫描任意深度 *.model3.json，按 组/角色 两级落位（自动跳过 live2d/model 等通用容器层）
    for (const c3Entry of this.listRawFiles(resMgr, 'models/cubism3', '.model3.json')) {
      const roleDir = this.rawParentDir(c3Entry);
      const rel = roleDir.substring('models/cubism3/'.length);
      const relParts = rel.split('/');
      const group = relParts.length > 1 ? relParts[0] : '未分组';
      const role = this.c3RoleName(relParts);
      const dest = `${modelsRoot}/cubism3/${group}/${role}`;
      const copied = await this.copyRawDirToSandbox(resMgr, roleDir, dest);
      if (copied) {
        moved++;
      }
    }
    // Cubism 2：遍历任意目录，找到含 model: xxx.moc 入口 json 的模型目录，保持相对结构复制
    const c2Root = 'models/cubism2';
    for (const dir of this.listRawDirs(resMgr, c2Root)) {
      if (await this.isCubism2RawDir(resMgr, dir)) {
        const rel = dir.substring(c2Root.length + 1);
        const dest = `${modelsRoot}/cubism2/${rel}`;
        const copied = await this.copyRawDirToSandbox(resMgr, dir, dest);
        if (copied) {
          moved++;
        }
      }
    }
    const scan = await modelScanner.scanAndPersist();
    await this.applyCategoryToNewModels(beforeKeys, category);
    Logger.info(TAG, '内置示例导入完成: 复制 %{public}d 个模型目录，新增 %{public}d 条', moved, scan.added);
    return { movedItems: moved, added: scan.added, version: 'mixed' };
  }

  /** 递归列出 rawfile 目录下全部文件路径（getRawFileListSync 对目录抛异常，按此区分文件/目录） */
  private listRawFiles(resMgr: resourceManager.ResourceManager, rawDir: string, suffix: string): string[] {
    const out: string[] = [];
    let items: string[] = [];
    try {
      items = resMgr.getRawFileListSync(rawDir);
    } catch (e) {
      return out;
    }
    for (const item of items) {
      const full = `${rawDir}/${item}`;
      if (item.endsWith(suffix)) {
        out.push(full);
      }
      out.push(...this.listRawFiles(resMgr, full, suffix));
    }
    return out;
  }

  /** 递归列出 rawfile 目录下全部目录路径（不含根自身） */
  private listRawDirs(resMgr: resourceManager.ResourceManager, rawDir: string): string[] {
    const out: string[] = [];
    let items: string[] = [];
    try {
      items = resMgr.getRawFileListSync(rawDir);
    } catch (e) {
      return out;
    }
    for (const item of items) {
      const full = `${rawDir}/${item}`;
      if (!this.isRawDir(resMgr, full)) {
        continue;
      }
      out.push(full);
      out.push(...this.listRawDirs(resMgr, full));
    }
    return out;
  }

  /** rawfile 路径是否为目录：getRawFileListSync 能列出子项即目录 */
  private isRawDir(resMgr: resourceManager.ResourceManager, path: string): boolean {
    try {
      resMgr.getRawFileListSync(path);
      return true;
    } catch (e) {
      return false;
    }
  }

  /** rawfile 目录是否含 Cubism 2 入口：目录内存在 model 字段以 .moc 结尾的 json */
  private async isCubism2RawDir(resMgr: resourceManager.ResourceManager, dir: string): Promise<boolean> {
    let items: string[] = [];
    try {
      items = resMgr.getRawFileListSync(dir);
    } catch (e) {
      return false;
    }
    for (const item of items) {
      if (!item.endsWith('.json')) {
        continue;
      }
      try {
        const bytes = resMgr.getRawFileContentSync(`${dir}/${item}`);
        const text = new util.TextDecoder('utf-8').decodeToString(bytes);
        const data = parseJsonLenient(text) as Record<string, Object> | null;
        const model = data ? data['model'] as string : undefined;
        if (typeof model === 'string' && model.endsWith('.moc')) {
          return true;
        }
      } catch (e) {
        // 读取/解析失败跳过
      }
    }
    return false;
  }

  /** 取 rawfile 路径的父目录 */
  private rawParentDir(path: string): string {
    const idx = path.lastIndexOf('/');
    return idx > 0 ? path.substring(0, idx) : '';
  }

  async importFromZip(context: common.UIAbilityContext, zipUri: string, category: string = '',
    onProgress?: (msg: string) => void): Promise<ImportResult> {
    const importRoot = `${context.cacheDir}/imports/${Date.now()}`;
    const zipPath = `${importRoot}/import.zip`;
    const unzipDir = `${importRoot}/unzip`;
    try {
      const beforeKeys = await this.collectEntryKeys();
      onProgress?.('正在复制压缩包…');
      await fs.mkdir(importRoot, true);
      await FileUtil.copyFile(zipUri, zipPath);

      onProgress?.('正在解压…');
      await fs.mkdir(unzipDir, true);
      await zlib.decompressFile(zipPath, unzipDir);

      onProgress?.('正在整理模型目录…');
      const version = await this.detectVersion(unzipDir);
      const movedItems = await this.relocate(unzipDir, `${context.filesDir}/models`, version);

      onProgress?.('正在扫描模型…');
      const scan = await modelScanner.scanAndPersist();
      const models = await modelStore.listModels();
      await this.applyCategoryToNewModels(beforeKeys, category);

      Logger.info(TAG, '导入完成: 移动 %{public}d 项，新增 %{public}d 条，版本=%{public}s',
        movedItems, scan.added, version);
      return { movedItems, added: scan.added, version };
    } catch (e) {
      Logger.error(TAG, '导入失败: %{public}s', JSON.stringify(e));
      throw new Error(`导入失败: ${JSON.stringify(e)}`);
    } finally {
      // 清理临时目录（尽力而为，失败不影响导入结果）
      try {
        await FileUtil.removeDir(importRoot);
      } catch (e) {
        Logger.warn(TAG, '清理临时目录失败: %{public}s', JSON.stringify(e));
      }
    }
  }

  /** 收集当前库内全部模型的 (version|entryPath) 键，用于识别本次新增 */
  private async collectEntryKeys(): Promise<string[]> {
    const models = await modelStore.listModels();
    const keys: string[] = [];
    for (const model of models) {
      keys.push(`${model.version}|${model.entryPath}`);
    }
    return keys;
  }

  /** 给本次新增的模型设置分类（分类仅导入时填写，之后只读） */
  private async applyCategoryToNewModels(beforeKeys: string[], category: string): Promise<void> {
    if (category === '') {
      return;
    }
    const models = await modelStore.listModels();
    for (const model of models) {
      const key = `${model.version}|${model.entryPath}`;
      if (beforeKeys.indexOf(key) < 0) {
        await modelStore.updateCategory(model.id, category);
      }
    }
  }

  /** 递归复制 rawfile 目录到沙箱（返回是否实际复制了新内容；目标已存在则跳过，保持幂等） */
  private async copyRawDirToSandbox(resMgr: resourceManager.ResourceManager, rawDir: string,
    destDir: string): Promise<boolean> {
    // API 24 上 fs.mkdir(path, true) 对已存在目录抛 EEXIST(13900015)，先判断再创建保证幂等
    if (!fs.accessSync(destDir)) {
      await fs.mkdir(destDir, true);
    }
    let copied = false;
    const items = resMgr.getRawFileListSync(rawDir);
    for (const item of items) {
      const rawPath = `${rawDir}/${item}`;
      const destPath = `${destDir}/${item}`;
      // 已存在则跳过（重复导入示例时避免覆盖冲突）
      if (fs.accessSync(destPath)) {
        continue;
      }
      if (this.isRawDir(resMgr, rawPath)) {
        if (await this.copyRawDirToSandbox(resMgr, rawPath, destPath)) {
          copied = true;
        }
      } else {
        const data = resMgr.getRawFileContentSync(rawPath);
        const file = fs.openSync(destPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.writeSync(file.fd, data.buffer);
        fs.closeSync(file);
        copied = true;
      }
    }
    return copied;
  }

  /** 识别解压内容属于哪个模型版本（优先 Cubism 3） */
  private async detectVersion(root: string): Promise<string> {
    const c3 = FileUtil.listFilesRecursive(root, '.model3.json');
    if (c3.length > 0) {
      return 'cubism3';
    }
    const c2 = FileUtil.listDirsRecursive(root);
    for (const dir of c2) {
      for (const name of fs.listFileSync(dir)) {
        if (name.endsWith('.json') && (await this.isCubism2Entry(`${dir}/${name}`))) {
          return 'cubism2';
        }
      }
    }
    return 'none';
  }

  /** 把解压内容移动到模型库对应版本目录（C2 保持相对结构；C3 拍平为 group/role 两级；目标已存在则补齐缺失） */
  private async relocate(unzipDir: string, modelsRoot: string, version: string): Promise<number> {
    if (version === 'none') {
      return 0;
    }
    if (version === 'cubism3') {
      // C3：把任意深度的 .model3.json 所在目录拍平到 cubism3/<group>/<role> 两级
      return this.relocateCubism3(unzipDir, `${modelsRoot}/cubism3`);
    }
    // C2 模型必须落在 model/ 子目录下（扫描器与渲染页都要求 entryPath 以 model/ 开头）。
    // zip 顶层若直接是模型目录（无 model 前缀），统一归入 model/；已带 model/ 前缀则保留。
    let targetRoot = `${modelsRoot}/${version}`;
    if (version === 'cubism2') {
      const topNames = fs.listFileSync(unzipDir);
      if (topNames.indexOf('model') < 0) {
        targetRoot = `${modelsRoot}/cubism2/model`;
      }
    }
    if (!fs.accessSync(targetRoot)) {
      await fs.mkdir(targetRoot, true);
    }
    let moved = 0;
    const names = fs.listFileSync(unzipDir);
    for (const name of names) {
      // 过滤 macOS 压缩残留（__MACOSX / ._ 文件），避免污染模型库
      if (name === '__MACOSX' || name.startsWith('._')) {
        Logger.info(TAG, '跳过压缩包垃圾文件: %{public}s', name);
        continue;
      }
      const src = `${unzipDir}/${name}`;
      const dest = `${targetRoot}/${name}`;
      if (fs.accessSync(dest)) {
        // 目标已存在：逐项补齐缺失文件（之前删除过的模型可被重新补回），不整项跳过
        moved += await this.mergeMissing(src, dest);
        continue;
      }
      await fs.rename(src, dest);
      moved++;
    }
    return moved;
  }

  /**
   * C3 导入归一化（对齐原项目 _import_target_rel + _normalize_model3_name）：
   * - 每个 *.model3.json 所在目录视为角色目录，拍平到 cubism3/<group>/<role>/
   *   （组 = zip 顶层容器名，无组用「未分组」；角色名 = 最后一个非通用容器层）
   * - 目标被占时依次回退到「父目录名/目录名」「未分组/目录名」，全部被占则逐项补齐缺失文件
   * - 目录内只有一个 model3.json 且名字 ≠ 目录名时重命名为 <目录名>.model3.json
   * 扫描器/渲染链按这两级布局查找，结构不满足会渲染成白板。
   */
  private async relocateCubism3(unzipDir: string, targetRoot: string): Promise<number> {
    if (!fs.accessSync(targetRoot)) {
      await fs.mkdir(targetRoot, true);
    }
    // 先移外层角色目录：嵌套 model3.json 会随父目录一并搬走，处理时按「目录是否还存在」跳过
    const entries = FileUtil.listFilesRecursive(unzipDir, '.model3.json')
      .sort((a: string, b: string) => a.split('/').length - b.split('/').length);
    const used: string[] = [];
    let moved = 0;
    for (const entry of entries) {
      const roleDir = entry.substring(0, entry.lastIndexOf('/'));
      if (roleDir === unzipDir) {
        // model3.json 直接躺在 zip 根目录，没有独立角色目录，无法归组
        Logger.warn(TAG, 'C3 入口无独立角色目录，跳过: %{public}s', entry);
        continue;
      }
      if (!fs.accessSync(roleDir)) {
        // 父角色目录已整体搬走（同目录多入口 / 嵌套入口随父目录移动），跳过
        continue;
      }
      const relDir = roleDir.substring(unzipDir.length + 1);
      const relParts = relDir.split('/');
      const candidates = this.c3TargetCandidates(relParts);
      let dest = '';
      for (const cand of candidates) {
        const full = `${targetRoot}/${cand}`;
        if (!fs.accessSync(full) && used.indexOf(full) < 0) {
          dest = full;
          break;
        }
      }
      if (dest === '') {
        // 全部目标被占：本批次已占用则跳过；磁盘已有旧模型则逐项补齐缺失文件（不覆盖）
        const primary = `${targetRoot}/${candidates[0]}`;
        if (used.indexOf(primary) >= 0) {
          Logger.info(TAG, 'C3 目标被本批次占用，跳过: %{public}s', relDir);
          continue;
        }
        moved += await this.mergeMissing(roleDir, primary);
        await this.normalizeC3EntryName(primary);
        continue;
      }
      const parent = dest.substring(0, dest.lastIndexOf('/'));
      if (!fs.accessSync(parent)) {
        await fs.mkdir(parent, true);
      }
      await fs.rename(roleDir, dest);
      used.push(dest);
      moved++;
      await this.normalizeC3EntryName(dest);
    }
    return moved;
  }

  /** C3 拍平目标候选（相对 cubism3 根），按优先级排列 */
  private c3TargetCandidates(relParts: string[]): string[] {
    const roleDirName = relParts[relParts.length - 1];
    const role = this.c3RoleName(relParts);
    const candidates: string[] = [];
    const push = (group: string, name: string): void => {
      const cand = `${group}/${name}`;
      if (candidates.indexOf(cand) < 0) {
        candidates.push(cand);
      }
    };
    if (relParts.length <= 1) {
      push('未分组', roleDirName);
    } else {
      push(relParts[0], role);
      push(relParts[relParts.length - 2], roleDirName);
      push('未分组', roleDirName);
    }
    return candidates;
  }

  /** 角色名 = 最后一个非通用容器层（跳过 live2d/model 等资源层），全通用时回退目录名 */
  private c3RoleName(relParts: string[]): string {
    if (relParts.length <= 1) {
      return relParts[0];
    }
    for (let i = relParts.length - 1; i >= 1; i--) {
      if (C3_GENERIC_CONTAINER_NAMES.indexOf(relParts[i].toLowerCase()) < 0) {
        return relParts[i];
      }
    }
    return relParts[relParts.length - 1];
  }

  /**
   * 规范化 model3.json 文件名：l2d.js 按 <目录名>.model3.json 查找入口。
   * 目录内只有一个入口且名字 ≠ 目录名时重命名（对齐原项目 _normalize_model3_name），
   * 多入口不处理（保留声明文件，扫描/渲染按目录名入口优先）。
   */
  private async normalizeC3EntryName(modelDir: string): Promise<void> {
    const expected = `${modelDir}/${FileUtil.basename(modelDir)}.model3.json`;
    if (fs.accessSync(expected)) {
      return;
    }
    const candidates = fs.listFileSync(modelDir).filter((n: string) => n.endsWith('.model3.json'));
    if (candidates.length !== 1) {
      return;
    }
    const src = `${modelDir}/${candidates[0]}`;
    try {
      await fs.rename(src, expected);
      Logger.info(TAG, 'C3 入口重命名: %{public}s → %{public}s', src, expected);
    } catch (e) {
      Logger.warn(TAG, 'C3 入口重命名失败: %{public}s, err=%{public}s', src, JSON.stringify(e));
    }
  }

  /** 递归把 src 中目标缺失的内容补进 dest；已存在的不覆盖，返回实际搬移数量 */
  private async mergeMissing(src: string, dest: string): Promise<number> {
    const srcStat = fs.statSync(src);
    if (!srcStat.isDirectory()) {
      if (!fs.accessSync(dest)) {
        await fs.rename(src, dest);
        return 1;
      }
      return 0;
    }
    if (!fs.accessSync(dest)) {
      await fs.rename(src, dest);
      return 1;
    }
    const destStat = fs.statSync(dest);
    if (!destStat.isDirectory()) {
      Logger.warn(TAG, '文件/目录类型冲突，跳过: %{public}s', dest);
      return 0;
    }
    let moved = 0;
    for (const name of fs.listFileSync(src)) {
      moved += await this.mergeMissing(`${src}/${name}`, `${dest}/${name}`);
    }
    // 源目录搬空后清理（临时目录最终也会被 finally 清理）
    if (fs.listFileSync(src).length === 0) {
      try {
        await fs.rmdir(src);
      } catch (e) {
        // 忽略
      }
    }
    return moved;
  }

  /**
   * 物理删除模型文件与缩略图（数据库记录由调用方删除）。
   * C3 删除角色整目录；C2 只删入口 json 及其独占引用的文件（同目录多入口时共享文件保留）。
   * 删除失败会向上抛出，由调用方决定是否删除数据库记录。
   */
  async removeModelFiles(context: common.UIAbilityContext, record: ModelRecord): Promise<void> {
    const modelsRoot = `${context.filesDir}/models`;
    if (record.version === 'cubism3') {
      // C3：一个角色目录 = 一个模型，整目录递归删除
      const roleDir = `${modelsRoot}/cubism3/${record.entryPath}`;
      await FileUtil.removeDir(roleDir);
      await this.pruneEmptyParents(roleDir, modelsRoot);
    } else {
      await this.removeCubism2Model(modelsRoot, record);
    }
    // 缩略图按 entryPath 哈希命名，一并删除
    try {
      await fs.unlink(thumbnailService.thumbPath(record.entryPath));
    } catch (e) {
      // 缩略图可能未生成，忽略
    }
  }

  /** 清空整个模型库目录（含全部模型文件与删除残留的孤儿目录），失败上抛 */
  async clearModelsRoot(context: common.UIAbilityContext): Promise<void> {
    const modelsRoot = `${context.filesDir}/models`;
    await FileUtil.removeDir(modelsRoot);
    Logger.info(TAG, '模型库目录已清空: %{public}s', modelsRoot);
  }

  /**
   * C2 模型删除：一个目录可能包含多个入口 json（如 model.json / index.json 或多个角色）。
   * 只删除本入口 json 和它独占引用的文件；同目录其它入口仍引用的共享文件保留。
   */
  private async removeCubism2Model(modelsRoot: string, record: ModelRecord): Promise<void> {
    const entryFile = `${modelsRoot}/cubism2/${record.entryPath}`;
    const dir = entryFile.substring(0, entryFile.lastIndexOf('/'));
    let owned: string[] = [];
    try {
      if (fs.accessSync(entryFile)) {
        const text = await fs.readText(entryFile);
        const data = parseJsonLenient(text) as Record<string, Object> | null;
        if (data) {
          owned = this.collectC2Refs(data);
        }
      }
    } catch (e) {
      Logger.warn(TAG, '解析 C2 入口失败，仅删除入口 json: %{public}s', record.entryPath);
    }
    // 同目录其它入口 json（用于判断共享引用）
    const siblingEntries: string[] = [];
    if (fs.accessSync(dir)) {
      for (const name of fs.listFileSync(dir)) {
        const full = `${dir}/${name}`;
        if (name.endsWith('.json') && full !== entryFile) {
          siblingEntries.push(full);
        }
      }
    }
    // 入口 json 本身
    if (fs.accessSync(entryFile)) {
      await fs.unlink(entryFile);
    }
    // 引用文件：仍被其它入口引用则保留，否则删除
    for (const rel of owned) {
      const full = `${dir}/${rel}`;
      if (!fs.accessSync(full)) {
        continue;
      }
      if (await this.isReferencedByOthers(dir, rel, siblingEntries)) {
        continue;
      }
      try {
        await fs.unlink(full);
        Logger.info(TAG, '删除 C2 模型引用文件: %{public}s', full);
      } catch (e) {
        Logger.warn(TAG, '删除引用文件失败: %{public}s, err=%{public}s', full, JSON.stringify(e));
      }
    }
    // 自底向上清理空目录（保留 model 根）
    await this.pruneEmptyParents(dir, modelsRoot);
  }

  /** 提取 C2 入口 json 引用的相对文件路径（model/textures/motions/physics/pose/expressions） */
  private collectC2Refs(data: Record<string, Object>): string[] {
    const refs: string[] = [];
    const push = (ref: Object | undefined): void => {
      if (typeof ref === 'string' && ref !== '') {
        const norm = this.normalizeRelPath(ref);
        if (norm !== '' && refs.indexOf(norm) < 0) {
          refs.push(norm);
        }
      }
    };
    push(data['model']);
    const textures = data['textures'] as Object[] | undefined;
    if (Array.isArray(textures)) {
      for (const t of textures) {
        push(t);
      }
    }
    for (const key of ['physics', 'pose']) {
      push(data[key]);
    }
    const motions = data['motions'] as Record<string, Object> | undefined;
    if (motions) {
      for (const group of Object.keys(motions)) {
        const items = motions[group] as Object[] | undefined;
        if (!items) {
          continue;
        }
        for (const item of items) {
          const entry = item as Record<string, Object>;
          push(entry['file']);
          push(entry['sound']);
        }
      }
    }
    const expressions = data['expressions'] as Object[] | undefined;
    if (Array.isArray(expressions)) {
      for (const exp of expressions) {
        push((exp as Record<string, Object>)['file']);
      }
    }
    return refs;
  }

  /** 相对路径归一化：去 ./ 与空段，越界的 .. 直接丢弃（不删除入口目录之外的文件） */
  private normalizeRelPath(ref: string): string {
    const parts: string[] = [];
    for (const seg of ref.split('/')) {
      if (seg === '' || seg === '.') {
        continue;
      }
      if (seg === '..') {
        if (parts.length > 0) {
          parts.pop();
        }
        continue;
      }
      parts.push(seg);
    }
    return parts.join('/');
  }

  /** 判断文件是否仍被同目录其它入口 json 引用（共享文件不删） */
  private async isReferencedByOthers(dir: string, rel: string, siblingEntries: string[]): Promise<boolean> {
    for (const sib of siblingEntries) {
      try {
        const text = await fs.readText(sib);
        const data = parseJsonLenient(text) as Record<string, Object> | null;
        if (data && this.collectC2Refs(data).indexOf(rel) >= 0) {
          return true;
        }
      } catch (e) {
        // 兄弟入口解析失败按不引用处理
      }
    }
    return false;
  }

  /** 自底向上删除空目录（保留 modelsRoot 本身；目录不存在时跳到其父目录继续） */
  private async pruneEmptyParents(dir: string, modelsRoot: string): Promise<void> {
    let cur = dir;
    while (cur.length > modelsRoot.length) {
      if (!fs.accessSync(cur)) {
        cur = cur.substring(0, cur.lastIndexOf('/'));
        continue;
      }
      const names = fs.listFileSync(cur);
      if (names.length > 0) {
        break;
      }
      await fs.rmdir(cur);
      cur = cur.substring(0, cur.lastIndexOf('/'));
    }
  }

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
}

/** 模块级单例 */
export const importService: ImportService = new ImportService();
