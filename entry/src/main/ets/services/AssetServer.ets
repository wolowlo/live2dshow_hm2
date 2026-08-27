import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import resourceManager from '@ohos.resourceManager';
import { Logger } from '../common/Logger';

const TAG = 'AssetServer';
// 本地回环地址：可解析 IP 免 DNS，所有请求由 onInterceptRequest 在发出前接管
const BASE_HOST = 'http://127.0.0.1:17890';
// Cubism 3 引擎脚本白名单（文件名不冲突，按名区分 c2/c3）
const C3_SCRIPTS: string[] = [
  'live2dcubismcore.min.js',
  'pixi.min.js',
  'live2dcubismframework.js',
  'live2dcubismpixi.js',
  'l2d.js',
  'charData.js',
];

/** 资源来源类型 */
interface AssetLocation {
  source: 'raw' | 'sandbox';
  path: string;
  /** 沙箱根目录：缺省 models，'bg' 为 backgrounds（舞台背景图） */
  root?: 'models' | 'bg';
}

/** 根据扩展名返回 MIME 类型，未知类型一律按二进制流处理 */
function mimeOf(path: string): string {
  const lower = path.toLowerCase();
  if (lower.endsWith('.html')) return 'text/html';
  if (lower.endsWith('.js')) return 'application/javascript';
  if (lower.endsWith('.json')) return 'application/json';
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.mp3')) return 'audio/mpeg';
  return 'application/octet-stream';
}

/**
 * 渲染资源供给服务：Web 组件的 onInterceptRequest 处理器。
 * - 引擎脚本与渲染页：rawfile（打包资源，只读）
 * - 模型文件：优先沙箱 filesDir/models/（用户导入），缺失时回退 rawfile（内置示例）
 */
export class AssetServer {
  private resMgr: resourceManager.ResourceManager | null = null;
  private sandboxModelsDir: string = '';
  private sandboxBgDir: string = '';

  init(context: common.UIAbilityContext): void {
    this.resMgr = context.resourceManager;
    this.sandboxModelsDir = `${context.filesDir}/models`;
    this.sandboxBgDir = `${context.filesDir}/backgrounds`;
    Logger.info(TAG, '初始化完成，模型根目录: %{public}s', this.sandboxModelsDir);
  }

  /** 供 Web 组件 onInterceptRequest 回调调用；返回 null 表示放行 */
  handle(request: WebResourceRequest): WebResourceResponse | null {
    const urlStr = request.getRequestUrl();
    if (!urlStr.startsWith(BASE_HOST)) {
      return null;
    }
    const pathname = this.parsePathname(urlStr);
    if (pathname === '') {
      return null;
    }
    // favicon 无实际资源：返回空响应，避免放行后产生连接错误噪音
    if (pathname === '/favicon.ico') {
      const emptyResp = new WebResourceResponse();
      emptyResp.setResponseData('');
      emptyResp.setResponseCode(204);
      emptyResp.setReasonMessage('No Content');
      return emptyResp;
    }
    const location = this.locate(pathname);
    if (!location) {
      Logger.warn(TAG, '无映射: %{public}s', pathname);
      return null;
    }
    const data = this.readAsset(location);
    if (!data) {
      Logger.warn(TAG, '资源不存在: %{public}s (%{public}s)', location.path, location.source);
      return null;
    }
    const resp = new WebResourceResponse();
    resp.setResponseData(data);
    resp.setResponseMimeType(mimeOf(location.path));
    resp.setResponseEncoding('utf-8');
    resp.setResponseCode(200);
    resp.setReasonMessage('OK');
    resp.setResponseHeader([
      { headerKey: 'Access-Control-Allow-Origin', headerValue: '*' },
    ]);
    return resp;
  }

  /** 去掉查询串并解码，得到以 / 开头的路径 */
  private parsePathname(urlStr: string): string {
    try {
      const hostStart = urlStr.indexOf(BASE_HOST);
      const pathOnly = hostStart >= 0 ? urlStr.substring(hostStart + BASE_HOST.length) : urlStr;
      const qIndex = pathOnly.indexOf('?');
      const noQuery = qIndex >= 0 ? pathOnly.substring(0, qIndex) : pathOnly;
      return decodeURIComponent(noQuery);
    } catch (e) {
      Logger.error(TAG, 'URL 解析失败: %{public}s', urlStr);
      return '';
    }
  }

  /** 路径 → 资源定位：模型请求优先沙箱，其余走 rawfile */
  private locate(pathname: string): AssetLocation | null {
    if (pathname === '/render3.html') {
      return { source: 'raw', path: 'engines/cubism3/render3.html' };
    }
    if (pathname === '/render.html') {
      return { source: 'raw', path: 'engines/cubism2/render.html' };
    }
    if (pathname.startsWith('/js/')) {
      const file = pathname.substring(4);
      if (C3_SCRIPTS.indexOf(file) >= 0) {
        return { source: 'raw', path: `engines/cubism3/js/${file}` };
      }
      return { source: 'raw', path: `engines/cubism2/js/${file}` };
    }
    const c3Prefix = '/api/live2d/assets/cubism3/model/';
    if (pathname.startsWith(c3Prefix)) {
      const rel = pathname.substring(c3Prefix.length);
      return { source: 'sandbox', path: `cubism3/${rel}` };
    }
    const c2Prefix = '/api/live2d/assets/cubism2/';
    if (pathname.startsWith(c2Prefix)) {
      const rel = pathname.substring(c2Prefix.length);
      return { source: 'sandbox', path: `cubism2/${rel}` };
    }
    // 舞台背景图片：沙箱 backgrounds/（截图合成 / 渲染页背景用）
    const bgPrefix = '/api/bg/';
    if (pathname.startsWith(bgPrefix)) {
      const rel = pathname.substring(bgPrefix.length);
      return { source: 'sandbox', path: rel, root: 'bg' };
    }
    return null;
  }

  /** 按定位读取：沙箱优先，rawfile 回退 */
  private readAsset(location: AssetLocation): ArrayBuffer | null {
    if (location.source === 'sandbox') {
      const base = location.root === 'bg' ? this.sandboxBgDir : this.sandboxModelsDir;
      const sandboxData = this.readSandboxFrom(base, location.path);
      if (sandboxData) {
        return sandboxData;
      }
      // 回退到内置示例模型（rawfile）
      return this.readRawfile(`models/${location.path}`);
    }
    return this.readRawfile(location.path);
  }

  private readSandboxFrom(baseDir: string, relPath: string): ArrayBuffer | null {
    if (baseDir === '') {
      return null;
    }
    const fullPath = `${baseDir}/${relPath}`;
    let file: fs.File | null = null;
    try {
      file = fs.openSync(fullPath, fs.OpenMode.READ_ONLY);
      const size = fs.statSync(file.fd).size;
      const buffer = new ArrayBuffer(size);
      fs.readSync(file.fd, buffer);
      return buffer;
    } catch (e) {
      return null;
    } finally {
      if (file) {
        try {
          fs.closeSync(file);
        } catch (e) {
          Logger.warn(TAG, '关闭沙箱文件失败: %{public}s', fullPath);
        }
      }
    }
  }

  private readRawfile(rawPath: string): ArrayBuffer | null {
    if (!this.resMgr) {
      return null;
    }
    try {
      return this.resMgr.getRawFileContentSync(rawPath).buffer;
    } catch (e) {
      return null;
    }
  }
}

/** 模块级单例：全应用共享一个资源服务实例 */
export const assetServer: AssetServer = new AssetServer();
