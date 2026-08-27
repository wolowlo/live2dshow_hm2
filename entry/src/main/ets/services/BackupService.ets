import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { ModelRecord } from './ModelRecord';
import { modelStore } from './ModelStore';
import { modelScanner } from './ModelScanner';
import { thumbnailService } from './ThumbnailService';
import { themeManager } from './ThemeManager';
import { Logger } from '../common/Logger';
import { FileUtil } from '../common/FileUtil';

const TAG = 'Backup';
/** 备份包标识：与 manifest.json 校验用 */
const BACKUP_APP = 'live2dview';
/** 备份格式版本 */
const BACKUP_FORMAT = 1;
/** 备份的全局偏好 key（主题/舞台背景/速览网格密度） */
const PREF_KEYS: string[] = ['themeId', 'stageBg', 'overviewGridCols'];
/** 每模型视角偏好 key 前缀（view_<modelId>） */
const VIEW_KEY_PREFIX = 'view_';

/** 备份中的单模型条目（含视角偏好原始 JSON，恢复时按 entry_path 重映射 id） */
interface BackupModelItem {
  version: string;
  groupName: string;
  roleName: string;
  entryPath: string;
  displayName: string;
  category: string;
  favorite: number;
  broken: number;
  createdAt: number;
  canvasW: number;
  canvasH: number;
  actions: string[];
  /** 视角偏好 JSON（view_<id> 的值，可能为空串） */
  view: string;
}

/** 备份数据文件（data.json） */
interface BackupPayload {
  models: BackupModelItem[];
  categories: string[];
  prefs: Record<string, string>;
}

/**
 * 备份与恢复服务：
 * - 导出：models/ + thumbnails/ + backgrounds/ + 收藏快照 + DB 与偏好数据 → zip（DocumentViewPicker 保存，免权限）
 * - 恢复：选 zip → 解压 → 覆盖模型/缩略图/背景目录 → 重建 DB → 重映射视角偏好 → 重扫校验
 * 备份包为自描述格式（manifest.json + data.json + 目录），恢复前请先手动导出一份当前备份以防误覆盖。
 */
class BackupService {
  /** 导出备份：打包为 zip 并让用户选择保存位置；用户取消返回 '' */
  async exportBackup(context: common.UIAbilityContext, onProgress?: (msg: string) => void): Promise<string> {
    const filesDir = context.filesDir;
    const stamp = `${Date.now()}`;
    const staging = `${filesDir}/backup_staging_${stamp}`;
    const zipPath = `${filesDir}/backup_${stamp}.zip`;
    try {
      onProgress?.('正在导出数据…');
      const payload = await this.collectPayload();
      if (!fs.accessSync(staging)) {
        await fs.mkdir(staging, true);
      }
      this.writeText(`${staging}/manifest.json`,
        JSON.stringify({ app: BACKUP_APP, format: BACKUP_FORMAT, createdAt: Date.now() }));
      this.writeText(`${staging}/data.json`, JSON.stringify(payload));

      onProgress?.('正在复制模型文件…');
      await FileUtil.copyDir(`${filesDir}/models`, `${staging}/models`);
      onProgress?.('正在复制缩略图…');
      await FileUtil.copyDir(`${filesDir}/thumbnails`, `${staging}/thumbnails`);
      onProgress?.('正在复制背景图…');
      await FileUtil.copyDir(`${filesDir}/backgrounds`, `${staging}/backgrounds`);

      onProgress?.('正在压缩打包…');
      const options: zlib.Options = {};
      await zlib.compressFile(staging, zipPath, options);

      onProgress?.('正在选择保存位置…');
      return await this.saveToDocument(context, zipPath, `live2d_backup_${stamp}.zip`);
    } catch (e) {
      Logger.error(TAG, '导出备份失败: %{public}s', JSON.stringify(e));
      throw new Error(`导出备份失败: ${JSON.stringify(e)}`);
    } finally {
      try {
        await FileUtil.removeDir(staging);
      } catch (e) {
        Logger.warn(TAG, '清理临时目录失败: %{public}s', JSON.stringify(e));
      }
      try {
        if (fs.accessSync(zipPath)) {
          fs.unlinkSync(zipPath);
        }
      } catch (e) {
        /* 临时 zip 清理失败忽略 */
      }
    }
  }

  /** 导入备份：覆盖恢复，返回恢复后的模型总数 */
  async importBackup(context: common.UIAbilityContext, zipUri: string,
    onProgress?: (msg: string) => void): Promise<number> {
    const filesDir = context.filesDir;
    const importRoot = `${context.cacheDir}/backup_imports/${Date.now()}`;
    const zipPath = `${importRoot}/backup.zip`;
    const unzipDir = `${importRoot}/unzip`;
    try {
      await fs.mkdir(importRoot, true);
      onProgress?.('正在复制备份包…');
      await FileUtil.copyFile(zipUri, zipPath);

      onProgress?.('正在解压…');
      await fs.mkdir(unzipDir, true);
      await zlib.decompressFile(zipPath, unzipDir);

      const root = this.locateBackupRoot(unzipDir);
      const manifest = this.parseJson<Record<string, string>>(`${root}/manifest.json`);
      if (manifest['app'] !== BACKUP_APP) {
        throw new Error('不是 Live2D 查看器的备份包');
      }
      const payload = this.parseJson<BackupPayload>(`${root}/data.json`);
      if (!payload || !Array.isArray(payload.models)) {
        throw new Error('备份数据缺失或损坏');
      }

      onProgress?.('正在恢复模型文件…');
      await this.replaceDir(`${root}/models`, `${filesDir}/models`);
      // 缩略图直接采用备份内旧图：文件名按 entryPath 哈希命名（与模型 ID 无关），
      // 恢复后 models/ 目录整体替换、entryPath 不变，备份缩略图天然匹配，无需重新生成
      //（1000+ 模型全量重新生成缩略图耗时过长）；备份内的失败标记 failed.json 一并恢复，
      // 并通过 init 重新加载到内存，恢复后缩略图队列直接判定为已齐备
      onProgress?.('正在恢复缩略图…');
      await this.replaceDir(`${root}/thumbnails`, `${filesDir}/thumbnails`);
      thumbnailService.init(`${filesDir}/thumbnails`);
      await this.replaceDir(`${root}/backgrounds`, `${filesDir}/backgrounds`);

      onProgress?.('正在重建模型数据…');
      const records: ModelRecord[] = [];
      for (const m of payload.models) {
        const rec = new ModelRecord(m.version, m.groupName, m.roleName, m.entryPath, m.displayName, m.category, m.actions);
        rec.favorite = m.favorite;
        rec.broken = m.broken;
        rec.createdAt = m.createdAt;
        rec.canvasW = m.canvasW;
        rec.canvasH = m.canvasH;
        records.push(rec);
      }
      const idMap = await modelStore.importAll(records, payload.categories);
      // 视角偏好按 entry_path 重映射到新 id
      for (const m of payload.models) {
        if (m.view !== '') {
          const newId = idMap.get(`${m.version}|${m.entryPath}`);
          if (newId !== undefined) {
            themeManager.putPref(`${VIEW_KEY_PREFIX}${newId}`, m.view);
          }
        }
      }
      // 全局偏好（主题/背景/网格密度）
      for (const key of PREF_KEYS) {
        const v = payload.prefs[key];
        if (v !== undefined && v !== '') {
          themeManager.putPref(key, v);
        }
      }
      const themeId = payload.prefs['themeId'];
      if (themeId !== undefined && themeId !== '') {
        themeManager.setTheme(themeId);
      }
      const gridCols = parseInt(payload.prefs['overviewGridCols'] ?? '0');
      if (gridCols === 3 || gridCols === 4 || gridCols === 5) {
        AppStorage.setOrCreate('overviewGridCols', gridCols);
      }

      onProgress?.('正在重新扫描校验…');
      const scan = await modelScanner.scanAndPersist();
      return scan.total;
    } catch (e) {
      Logger.error(TAG, '导入备份失败: %{public}s', JSON.stringify(e));
      throw new Error(`导入备份失败: ${JSON.stringify(e)}`);
    } finally {
      try {
        await FileUtil.removeDir(importRoot);
      } catch (e) {
        Logger.warn(TAG, '清理临时目录失败: %{public}s', JSON.stringify(e));
      }
    }
  }

  /** 收集数据库 + 偏好数据（不含文件） */
  private async collectPayload(): Promise<BackupPayload> {
    const exported = await modelStore.exportAll();
    const models = exported.models;
    const categories = exported.categories;
    const items: BackupModelItem[] = [];
    for (const m of models) {
      let view = '';
      try {
        view = await themeManager.getPref<string>(`${VIEW_KEY_PREFIX}${m.id}`, '');
      } catch (e) {
        view = '';
      }
      items.push({
        version: m.version,
        groupName: m.groupName,
        roleName: m.roleName,
        entryPath: m.entryPath,
        displayName: m.displayName,
        category: m.category,
        favorite: m.favorite,
        broken: m.broken,
        createdAt: m.createdAt,
        canvasW: m.canvasW,
        canvasH: m.canvasH,
        actions: m.actions,
        view: view,
      });
    }
    const prefs: Record<string, string> = {};
    for (const key of PREF_KEYS) {
      prefs[key] = await themeManager.getPref<string>(key, '');
    }
    return { models: items, categories, prefs };
  }

  /** DocumentViewPicker 保存：返回用户选择的目标 URI；取消返回 '' */
  private async saveToDocument(context: common.UIAbilityContext, srcPath: string, fileName: string): Promise<string> {
    const documentPicker = new picker.DocumentViewPicker(context);
    const opt = new picker.DocumentSaveOptions();
    opt.newFileNames = [fileName];
    opt.fileSuffixChoices = ['.zip'];
    const uris = await documentPicker.save(opt);
    if (uris.length === 0) {
      return '';
    }
    await FileUtil.copyFile(srcPath, uris[0]);
    return uris[0];
  }

  /** 解压根定位：兼容压缩包内是否带一层根目录 */
  private locateBackupRoot(unzipDir: string): string {
    if (fs.accessSync(`${unzipDir}/manifest.json`)) {
      return unzipDir;
    }
    const entries = fs.listFileSync(unzipDir);
    if (entries.length === 1) {
      const sub = `${unzipDir}/${entries[0]}`;
      if (fs.statSync(sub).isDirectory() && fs.accessSync(`${sub}/manifest.json`)) {
        return sub;
      }
    }
    throw new Error('备份包内容无效');
  }

  /** 目录整体替换：先删目标 destDir，再把源 srcDir 完整复制过去（源不存在则目标为空）。注意参数顺序是 (源, 目标) */
  private async replaceDir(srcDir: string, destDir: string): Promise<void> {
    await FileUtil.removeDir(destDir);
    if (fs.accessSync(srcDir)) {
      await FileUtil.copyDir(srcDir, destDir);
    }
  }

  private writeText(path: string, content: string): void {
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, content);
    fs.closeSync(file);
  }

  private parseJson<T>(path: string): T {
    const content = fs.readTextSync(path);
    return JSON.parse(content) as T;
  }
}

/** 模块级单例 */
export const backupService: BackupService = new BackupService();
