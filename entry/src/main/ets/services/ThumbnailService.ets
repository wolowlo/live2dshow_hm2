import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { ModelRecord } from './ModelRecord';
import { Logger } from '../common/Logger';
import { FileUtil } from '../common/FileUtil';

const TAG = 'Thumbnail';
/** 失败标记文件：记录缩略图生成失败的模型（下次跳过，重新生成时清除） */
const FAILED_FILE = 'failed.json';

/**
 * 模型静态缩略图：导入/扫描后从模型第一张贴图生成小图，供网格卡片展示。
 * 原项目网格页用惰性 iframe 实时预览，鸿蒙版按既定方案降级为静态缩略图。
 */
export class ThumbnailService {
  private thumbDir: string = '';
  /** 已失败模型的 entryPath 集合（持久化到 failed.json） */
  private failedKeys: Set<string> = new Set();

  init(thumbDir: string): void {
    this.thumbDir = thumbDir;
    this.failedKeys = this.loadFailed();
    Logger.info(TAG, '已加载失败标记: %{public}d 个', this.failedKeys.size);
  }

  /** 缩略图沙箱路径（entryPath 哈希命名，避免特殊字符进文件名） */
  thumbPath(entryPath: string): string {
    // PNG 保留贴图透明通道；_r 后缀为“渲染截图版”（旧贴图拼图块自动失效，重新生成）
    return `${this.thumbDir}/${this.hash(entryPath)}_r.png`;
  }

  /** 返回缺少缩略图的模型列表（用于渲染截图队列）；失败标记过的跳过 */
  listMissing(models: ModelRecord[]): ModelRecord[] {
    const missing: ModelRecord[] = [];
    for (const record of models) {
      if (!fs.accessSync(this.thumbPath(record.entryPath)) && !this.failedKeys.has(record.entryPath)) {
        missing.push(record);
      }
    }
    return missing;
  }

  /** 标记模型缩略图生成失败（持久化，下次扫描跳过） */
  markFailed(entryPath: string): void {
    if (entryPath === '' || this.failedKeys.has(entryPath)) {
      return;
    }
    this.failedKeys.add(entryPath);
    this.saveFailed();
    Logger.warn(TAG, '已标记缩略图失败: %{public}s', entryPath);
  }

  /** 清除全部失败标记（用户点“重新生成缩略图”时重新尝试） */
  clearFailed(): void {
    if (this.failedKeys.size === 0) {
      return;
    }
    this.failedKeys.clear();
    try {
      if (fs.accessSync(`${this.thumbDir}/${FAILED_FILE}`)) {
        fs.unlinkSync(`${this.thumbDir}/${FAILED_FILE}`);
      }
    } catch (e) {
      Logger.warn(TAG, '清除失败标记文件失败: %{public}s', JSON.stringify(e));
    }
    Logger.info(TAG, '已清除全部缩略图失败标记');
  }

  /** 清空全部缩略图与失败标记（清空模型库用） */
  async clearAll(): Promise<void> {
    this.failedKeys.clear();
    if (this.thumbDir === '') {
      return;
    }
    if (fs.accessSync(this.thumbDir)) {
      await FileUtil.removeDir(this.thumbDir);
    }
    // 目录不存在时，下次生成缩略图会自动重建
    Logger.info(TAG, '缩略图目录已清空');
  }

  private loadFailed(): Set<string> {
    const keys: Set<string> = new Set();
    if (this.thumbDir === '') {
      return keys;
    }
    try {
      const file = `${this.thumbDir}/${FAILED_FILE}`;
      if (!fs.accessSync(file)) {
        return keys;
      }
      const raw = fs.readTextSync(file);
      const list = JSON.parse(raw) as string[];
      if (Array.isArray(list)) {
        for (const item of list) {
          if (typeof item === 'string' && item !== '') {
            keys.add(item);
          }
        }
      }
    } catch (e) {
      Logger.warn(TAG, '读取失败标记文件异常: %{public}s', JSON.stringify(e));
    }
    return keys;
  }

  private saveFailed(): void {
    if (this.thumbDir === '') {
      return;
    }
    try {
      if (!fs.accessSync(this.thumbDir)) {
        fs.mkdirSync(this.thumbDir);
      }
      const file = fs.openSync(`${this.thumbDir}/${FAILED_FILE}`,
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      const data = JSON.stringify(Array.from(this.failedKeys));
      fs.writeSync(file.fd, data);
      fs.closeSync(file);
    } catch (e) {
      Logger.warn(TAG, '写入失败标记文件异常: %{public}s', JSON.stringify(e));
    }
  }

  /** 保存渲染页导出的 PNG dataURL（canvas.toDataURL 经 runJavaScript 取回） */
  async saveBase64(record: ModelRecord, dataUrl: string): Promise<void> {
    try {
      if (this.thumbDir === '' || !dataUrl.startsWith('data:image/png')) {
        throw new Error(`thumbDir 未初始化或 dataUrl 格式异常: dir=${this.thumbDir}`);
      }
      const comma = dataUrl.indexOf(',');
      if (comma < 0) {
        throw new Error('dataUrl 缺少逗号');
      }
      const helper = new util.Base64Helper();
      const bytes = helper.decodeSync(dataUrl.substring(comma + 1));
      if (bytes.byteLength === 0) {
        throw new Error('base64 解码为空');
      }
      if (!fs.accessSync(this.thumbDir)) {
        await fs.mkdir(this.thumbDir, true);
      }
      const destPath = this.thumbPath(record.entryPath);
      const file = fs.openSync(destPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
      fs.writeSync(file.fd, buffer);
      fs.closeSync(file);
    } catch (e) {
      const msg = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      Logger.error(TAG, '保存缩略图失败: %{public}s, 长度=%{public}d', msg, dataUrl.length);
      // 失败必须向上抛：调用方据此打失败标记并跳过，避免下次启动反复重试
      throw e instanceof Error ? e : new Error(msg);
    }
  }

  private hash(value: string): string {
    let h = 0;
    for (let i = 0; i < value.length; i++) {
      h = (h * 31 + value.charCodeAt(i)) >>> 0;
    }
    return h.toString(16);
  }
}

/** 模块级单例 */
export const thumbnailService: ThumbnailService = new ThumbnailService();
