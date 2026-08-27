import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { themeManager } from './ThemeManager';
import { Logger } from '../common/Logger';

const TAG = 'BackgroundService';
/** 背景图压缩长边上限（px）：舞台宽度一般 <800vp，1280 足够清晰且省内存 */
const BG_MAX_EDGE = 1280;
/** 背景存储 key（preferences app_settings） */
const PREF_KEY = 'stageBg';

/** 舞台背景选项：color=主题纯色（无背景），image=自定义图片 */
export interface StageBgOption {
  type: 'color' | 'image';
  /** type=image 时的沙箱文件名（backgrounds/ 目录下） */
  fileName: string;
}

/** 默认背景：主题纯色 */
export const DEFAULT_STAGE_BG: StageBgOption = { type: 'color', fileName: '' };

/**
 * 舞台背景服务：
 * - 相册选图导入（PhotoViewPicker 无需权限），ImagePacker 等比压缩后存沙箱 backgrounds/
 * - 背景为全局单一设置，preferences 持久化（与主题共用 app_settings）
 */
class BackgroundService {
  private bgDir: string = '';

  init(context: common.UIAbilityContext): void {
    this.bgDir = `${context.filesDir}/backgrounds`;
  }

  /** 背景目录（渲染/缩略图拼路径用） */
  getDir(): string {
    return this.bgDir;
  }

  /** 已导入的背景文件名列表（最新在前） */
  listImages(): string[] {
    try {
      if (this.bgDir === '' || !fs.accessSync(this.bgDir)) {
        return [];
      }
      const imgs = fs.listFileSync(this.bgDir).filter((f: string) => /\.(png|jpe?g|webp)$/i.test(f));
      imgs.sort((a: string, b: string) => b.localeCompare(a));
      return imgs;
    } catch (e) {
      Logger.warn(TAG, '列出背景失败: %{public}s', JSON.stringify(e));
      return [];
    }
  }

  /** 当前背景：读偏好；文件已丢失/解析失败时回退主题纯色 */
  async loadCurrent(): Promise<StageBgOption> {
    const raw = await themeManager.getPref<string>(PREF_KEY, '');
    if (raw === '') {
      return { type: 'color', fileName: '' };
    }
    try {
      const obj = JSON.parse(raw) as StageBgOption;
      if (obj.type === 'image' && obj.fileName !== '' && this.exists(obj.fileName)) {
        return { type: 'image', fileName: obj.fileName };
      }
      return { type: 'color', fileName: '' };
    } catch (e) {
      return { type: 'color', fileName: '' };
    }
  }

  /** 保存当前背景 */
  saveCurrent(opt: StageBgOption): void {
    themeManager.putPref(PREF_KEY, JSON.stringify(opt));
  }

  /** 从相册选图导入（压缩后存沙箱），返回新文件名；取消返回 '' */
  async importFromGallery(): Promise<string> {
    const photoPicker = new picker.PhotoViewPicker();
    const result = await photoPicker.select({
      MIMEType: picker.PhotoViewMIMETypes.IMAGE_TYPE,
      maxSelectNumber: 1,
    });
    if (result.photoUris.length === 0) {
      return '';
    }
    const uri = result.photoUris[0];
    // 官方建议：不要在 picker 回调栈内直接打开文件，转异步延迟处理
    await new Promise<void>((resolve: () => void) => setTimeout(resolve, 0));
    const fileName = `bg_${Date.now()}_${Math.floor(Math.random() * 1000)}.jpg`;
    await this.compressToFile(uri, `${this.bgDir}/${fileName}`);
    return fileName;
  }

  /**
   * 删除背景文件。
   * @returns 是否删除成功（文件不存在视为失败，调用方据此提示）
   */
  removeImage(fileName: string): boolean {
    try {
      if (fileName !== '' && this.exists(fileName)) {
        fs.unlinkSync(`${this.bgDir}/${fileName}`);
        return true;
      }
    } catch (e) {
      Logger.warn(TAG, '删除背景失败: %{public}s', JSON.stringify(e));
    }
    return false;
  }

  /** 背景文件是否存在 */
  exists(fileName: string): boolean {
    try {
      return fileName !== '' && fs.accessSync(`${this.bgDir}/${fileName}`);
    } catch (e) {
      return false;
    }
  }

  /** 等比压缩到长边 ≤1280 并写为 JPEG（90% 质量） */
  private async compressToFile(uri: string, destPath: string): Promise<void> {
    let source: image.ImageSource | null = null;
    let pixelMap: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    let srcFd: number = -1;
    try {
      if (!fs.accessSync(this.bgDir)) {
        fs.mkdirSync(this.bgDir, true);
      }
      // 相册 URI（file://media/...）需先以只读方式打开拿 fd 再创建 ImageSource，
      // 直接传 uri 字符串给 createImageSource 在部分机型上会失败
      srcFd = fs.openSync(uri, fs.OpenMode.READ_ONLY).fd;
      source = image.createImageSource(srcFd);
      const info = await source.getImageInfo();
      const srcW = info.size.width;
      const srcH = info.size.height;
      let tw = srcW;
      let th = srcH;
      if (Math.max(srcW, srcH) > BG_MAX_EDGE) {
        if (srcW >= srcH) {
          tw = BG_MAX_EDGE;
          th = Math.max(1, Math.round(srcH * BG_MAX_EDGE / srcW));
        } else {
          th = BG_MAX_EDGE;
          tw = Math.max(1, Math.round(srcW * BG_MAX_EDGE / srcH));
        }
      }
      pixelMap = await source.createPixelMap({
        desiredSize: { width: tw, height: th },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      });
      packer = image.createImagePacker();
      const packed = await packer.packing(pixelMap, { format: 'image/jpeg', quality: 90 });
      const file = fs.openSync(destPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, packed);
      fs.closeSync(file.fd);
      Logger.info(TAG, '背景导入完成: %{public}dx%{public}d -> %{public}dx%{public}d', srcW, srcH, tw, th);
    } finally {
      try {
        if (pixelMap !== null) {
          pixelMap.release();
        }
      } catch (e) {
        /* 释放失败忽略 */
      }
      try {
        if (source !== null) {
          source.release();
        }
      } catch (e) {
        /* 释放失败忽略 */
      }
      try {
        if (packer !== null) {
          packer.release();
        }
      } catch (e) {
        /* 释放失败忽略 */
      }
      if (srcFd >= 0) {
        try {
          fs.closeSync(srcFd);
        } catch (e) {
          /* 关闭失败忽略 */
        }
      }
    }
  }
}

export const backgroundService = new BackgroundService();
