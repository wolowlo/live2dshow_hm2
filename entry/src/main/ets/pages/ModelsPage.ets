import { common } from '@kit.AbilityKit';
import { display, promptAction } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { util } from '@kit.ArkTS';
import { modelStore } from '../services/ModelStore';
import { assetServer } from '../services/AssetServer';
import { thumbnailService } from '../services/ThumbnailService';
import { importService } from '../services/ImportService';
import { backgroundService, StageBgOption } from '../services/BackgroundService';
import { themeManager, AppTheme } from '../services/ThemeManager';
import { ModelRecord } from '../services/ModelRecord';
import { CategoryEntry } from '../services/ModelStore';
import { Logger } from '../common/Logger';
import { bumpModelDbVersion } from '../common/AppGlobal';

const TAG = 'ModelsPage';
const BASE_URL = 'http://127.0.0.1:17890';
/** 未分类筛选项的选中标记（不与真实分类名冲突） */
const CAT_UNASSIGNED = '__unassigned__';

/** 舞台截图传给渲染页的背景规格（JSON 序列化后注入 Web） */
interface StageShotBgSpec {
  type: 'color' | 'image' | 'none';
  /** type=color 时的背景色（hex，如 #FDF1F6） */
  color?: string;
  /** type=image 时的背景图 URL（/api/bg/ 路由） */
  url?: string;
}

/**
 * 模型库页：
 * - 单一“全部”视图：顶部常驻舞台 + 下方左右滚动模型卡槽
 * - 卡槽展示缩略图/名称/收藏/坏/删除，点击加载到舞台
 * 顶部提供收藏/坏/分类/版本筛选。
 */
@Component
export struct ModelsPage {
  @State selectedPath: string = '';
  @State statusMsg: string = '';
  @State models: ModelRecord[] = [];
  @State favoriteOnly: boolean = false;
  /** 版本筛选：all | cubism2 | cubism3（首页按钮可驱动） */
  @State versionFilter: string = 'all';
  /** 带版本维度的分类列表（菜单标注 C2/C3） */
  @State categoryEntries: CategoryEntry[] = [];
  /** 选中分类：''=全部，CAT_UNASSIGNED=未分类，否则 version|name */
  @State selectedCategoryKey: string = '';
  @StorageProp('modelDbVersion') @Watch('onDbVersionChange') modelDbVersion: number = 0;
  /** 首页按钮写入的版本选择（P0-1） */
  @StorageProp('modelsVersion') @Watch('onExternalVersion') externalVersion: string = '';
  /** 缩略图版本：后台渲染截图完成后递增，卡槽据此重建卡片刷新图片 */
  @StorageProp('thumbVersion') thumbVersion: number = 0;
  @StorageProp('themeId') themeId: string = 'pink';
  /** 速览页点击的模型路径：收到后重置筛选并定位到该模型 */
  @StorageProp('overviewSelectPath') @Watch('onOverviewSelect') overviewSelectPath: string = '';
  /** 双层舞台：切换时旧层平移出、新层同时切入（胶片效果） */
  private webControllers: webview.WebviewController[] = [
    new webview.WebviewController(),
    new webview.WebviewController(),
  ];
  /** 当前展示层（0/1） */
  @State activeWebIndex: number = 0;
  /** 每层是否已加载过页面（同类型切换走 JS） */
  private webLoadedFlags: boolean[] = [false, false];
  /** 每层当前页面类型（cubism2 | cubism3 | ''） */
  private pageVersionFlags: string[] = ['', ''];
  /** 每层当前 C2 画布尺寸 */
  private canvasWFlags: number[] = [0, 0];
  private canvasHFlags: number[] = [0, 0];
  /** 每层当前已加载/预加载的模型 entryPath（避免重复加载） */
  private layerEntryPaths: string[] = ['', ''];
  /** 每层整页加载就绪检测状态 */
  private fullLoadPendingFlags: boolean[] = [false, false];
  private fullLoadRetriesFlags: number[] = [0, 0];
  private fullLoadTimers: number[] = [-1, -1];
  /** 每层的平移/透明度（@State 数组元素变化不刷新 UI，故拆成独立变量） */
  @State stage0TranslateX: number = 0;
  @State stage0Opacity: number = 1;
  @State stage1TranslateX: number = 0;
  @State stage1Opacity: number = 0;
  /** 卡槽横向滚动器（舞台切换后跟随选中模型） */
  private slotScroller: Scroller = new Scroller();
  /** 卡槽可视宽度（onAreaChange 记录，按 4 个并列计算卡片宽） */
  @State slotViewWidth: number = 360;
  private pendingRecord: ModelRecord | null = null;
  /** 舞台滑动起点（左滑/右滑切换模型用） */
  private touchStartX: number = 0;
  private touchStartY: number = 0;
  /** 本次切换方向（1=下一个/左滑，-1=上一个/右滑），就绪后从对侧滑入 */
  private stageDirection: number = 1;
  /** 当前拖动方向（跟随 dx 实时更新，供回弹/切换用） */
  private dragDirection: number = 1;
  /** 上一次拖动方向（用于检测拖动中突然变向） */
  private lastDragDirection: number = 0;
  /** 水平跟手是否已激活（纵向滚动不激活，避免上下滑时舞台左右动） */
  private dragActive: boolean = false;
  /** 舞台实际宽度（onAreaChange 记录，用于出屏/滑入距离与悬浮按钮定位） */
  @State stageWidth: number = 400;
  /** 舞台实际高度（onAreaChange 记录，悬浮按钮/面板数值定位用） */
  @State stageHeight: number = 600;
  /** 动作面板实际高度（onAreaChange 记录，贴底定位用） */
  @State actionPanelH: number = 160;
  /** 沉浸提示实际宽度（onAreaChange 记录，顶部居中定位用） */
  @State immersiveHintW: number = 120;
  private stageInTimer: number = -1;
  /** 切换动画是否进行中（防重复触发） */
  private stageSwitching: boolean = false;
  /** 下拉收藏手势激活标志（纵向向下为主方向时进入，与水平切换互斥） */
  private pullingDown: boolean = false;
  /** 舞台整体下拉位移（下拉跟手 + 松手回弹） */
  @State stageTranslateY: number = 0;
  /** 下拉提示显隐 */
  @State pullHintVisible: boolean = false;
  /** 下拉触发阈值：原始触摸纵向位移（vp），超过即"拉到底" */
  private readonly PULL_TRIGGER: number = 120;
  /** 下拉阻尼系数：跟手位移 = dy * 阻尼 */
  private readonly PULL_DAMPING: number = 0.4;
  /** 下拉跟手上限（vp），防止舞台被拖出太远 */
  private readonly PULL_MAX: number = 150;
  /** 动作面板显隐（F1-1：动作手动切换） */
  @State showActionPanel: boolean = false;
  /** 动作轮播是否开启（面板内开关；手动播放动作时自动暂停，避免被轮播覆盖） */
  @State rotationOn: boolean = true;
  /** 当前手动播放的动作名（胶囊选中高亮；轮播开启时清空） */
  @State activeAction: string = '';
  /** 舞台沉浸模式（U1-1）：双击进入，系统返回键退出（Index onBackPress 拦截） */
  @StorageLink('stageImmersive') @Watch('onImmersiveChange') immersive: boolean = false;
  /** 沉浸期间待对齐的卡槽索引（List 卸载时记录，退出沉浸后补滚动，保证模型与卡槽对上） */
  private pendingSlotScrollIdx: number = -1;
  /** 沉浸退出提示显隐（进入沉浸后顶部短显 2 秒） */
  @State immersiveHintVisible: boolean = false;
  private immersiveHintTimer: number = -1;
  /** 双击检测：触点按下时间戳 + 上一次点按时间/坐标 */
  private tapDownTime: number = 0;
  private lastTapTime: number = 0;
  private lastTapX: number = 0;
  private lastTapY: number = 0;
  /** 模型视角：双指调整（缩放/X-Y 偏移），按模型 id 记忆。按 Web 层拆分独立状态——
   *  两个层分别持有各自模型的视角（预加载层不共享当前层视角，切换进场时才应用目标模型视角，避免切页跳动） */
  @State viewScale0: number = 1;
  @State viewX0: number = 0;
  @State viewY0: number = 0;
  @State viewScale1: number = 1;
  @State viewX1: number = 0;
  @State viewY1: number = 0;
  /** 双指起始快照（onTouch 自算：相对起始值更新，不依赖手势系统） */
  private pinchStartScale: number = 1;
  private pinchStartDist: number = 0;
  private panStartCX: number = 0;
  private panStartCY: number = 0;
  private panStartX: number = 0;
  private panStartY: number = 0;
  private panStartTime: number = 0;
  /** 多指触摸标志：双指操作进行中拦截单指 onTouch 逻辑（切换/下拉/双击） */
  private multiTouch: boolean = false;
  /** 当前按下的手指计数：Down +1 / Up -1 / Cancel 清零。多指模式退出与视角保存以此为准，
   *  不依赖 event.touches.length（真机上 Up 事件的 touches 内容并不可靠，曾导致 multiTouch 卡死） */
  private activePointers: number = 0;
  /** 视角缩放范围（防止双指误操作失控） */
  private readonly VIEW_SCALE_MIN: number = 0.5;
  private readonly VIEW_SCALE_MAX: number = 5;
  /** 舞台背景（全局设置，所有模型共用）：color=主题色，image=自定义图片 */
  @State stageBg: StageBgOption = { type: 'color', fileName: '' };
  /** 背景图完整渲染路径（''=无背景） */
  @State bgImageSrc: string = '';
  /** 背景版本号：设置页修改背景后递增，此处监听并重读（背景管理已迁移到设置页） */
  @StorageProp('bgVersion') @Watch('onBgVersionChange') bgVersion: number = 0;
  /** 截图进行中（防止连点重复触发） */
  @State shotBusy: boolean = false;

  aboutToAppear(): void {
    // 首帧兜底：用屏幕实际尺寸初始化舞台（全屏下窗口≈屏幕）。
    // 此前初值 400×600 靠 onAreaChange 异步回填，首帧/截图早帧时悬浮按钮
    // 按错误尺寸定位——宽屏上 3 个右上按钮跑到屏幕正中央、动作入口脱位消失。
    try {
      const d = display.getDefaultDisplaySync();
      const density = d.densityDPI / 160;
      // 宽：全屏宽（舞台 Stack 宽 = 全屏宽的 100%，首帧贴右正确）
      this.stageWidth = Math.round(d.width / density);
      // 高：屏高 − 常驻占用保守兜底。舞台 Stack 真实高度（非沉浸）
      // = 屏高 − 根 padding(40) − 标题行(~56) − 卡槽占位(128−30margin+padding≈98) − Stack 下 margin(30)
      // ≈ 屏高 − 224。动作入口 y=stageHeight−46，若首帧值大于真实 Stack 高，
      // 按钮会甩出 Stack 底部、落入卡槽区域被盖住（真机看不到）。
      // 取 −240 保守偏小，首帧只保证不超界，onAreaChange 随即回填精确值纠正。
      this.stageHeight = Math.max(300, Math.round(d.height / density) - 240);
    } catch (_e) {
      // display 查询失败则保持默认，onAreaChange 仍会回填精确值
    }
    this.initStageBg();
    if (this.overviewSelectPath !== '') {
      // 桌面卡片冷启动直达：直接选中目标模型（Watch 只在值变化后触发，首次挂载需主动处理）
      this.onOverviewSelect();
    } else {
      this.loadModels();
      this.loadCategories();
    }
  }

  aboutToDisappear(): void {
    // 离开模型页：清理定时器并退出沉浸/收起动作面板
    if (this.immersiveHintTimer >= 0) {
      clearTimeout(this.immersiveHintTimer);
      this.immersiveHintTimer = -1;
    }
    this.showActionPanel = false;
    if (this.immersive) {
      this.immersive = false;
    }
  }

  private theme(): AppTheme {
    return themeManager.getById(this.themeId);
  }

  // ── 舞台截图：Web 内合成「背景 + 模型」导出 PNG，不含任何 ArkUI 悬浮层 ──

  /** 截图当前舞台并保存到相册（免权限弹窗确认）；onlyModel=true 时不带背景，导出透明底模型 PNG */
  private async captureStage(onlyModel: boolean = false): Promise<void> {
    if (this.shotBusy) {
      return;
    }
    this.shotBusy = true;
    try {
      const ctrl = this.webControllers[this.activeWebIndex];
      // 1. 注入背景规格并预加载图片背景；仅模型模式注入 'none'，合成时跳过背景（透明底）
      const spec: StageShotBgSpec = onlyModel
        ? { type: 'none', color: '' }
        : this.stageBg.type === 'image' && this.stageBg.fileName !== ''
          ? { type: 'image', url: `/api/bg/${this.stageBg.fileName}` }
          : { type: 'color', color: this.theme().stageBg };
      const specJson = JSON.stringify(spec);
      await ctrl.runJavaScript(`window.__setStageBg && window.__setStageBg(${JSON.stringify(specJson)}); true`)
        .catch(() => '');
      // 2. 轮询合成截图：把当前视角变换（缩放/位移）传入 Web 复现，图片背景需等 onload，最多等 2s。
      //    位移用「相对舞台尺寸的比例」传递，绕开 vp 与 Web 像素的单位换算。
      const viewS = this.curViewScale();
      const viewRX = this.stageWidth > 0 ? this.curViewX() / this.stageWidth : 0;
      const viewRY = this.stageHeight > 0 ? this.curViewY() / this.stageHeight : 0;
      const shotJs = `window.__stageShot ? window.__stageShot(${viewS}, ${viewRX}, ${viewRY}, ${this.stageWidth}, ${this.stageHeight}) : ''`;
      let dataUrl = '';
      for (let i = 0; i < 10; i++) {
        const raw = await ctrl.runJavaScript(shotJs).catch(() => '');
        dataUrl = this.cleanJsReturn(raw);
        if (dataUrl.startsWith('data:image/png')) {
          break;
        }
        await this.sleep(200);
      }
      if (!dataUrl.startsWith('data:image/png')) {
        Logger.warn(TAG, '舞台截图导出为空');
        promptAction.showToast({ message: '截图失败，请稍后重试', duration: 1500 });
        return;
      }
      await this.saveShot(dataUrl, onlyModel ? 'Live2D模型' : 'Live2D截图',
        onlyModel ? '模型截图已保存到相册' : '截图已保存到相册');
    } catch (e) {
      Logger.error(TAG, '舞台截图失败: %{public}s', JSON.stringify(e));
      promptAction.showToast({ message: '截图失败，请重试', duration: 1500 });
    } finally {
      this.shotBusy = false;
    }
  }

  /** runJavaScript 返回 JSON 编码字符串（带引号），还原为真实字符串 */
  private cleanJsReturn(raw: string): string {
    try {
      return JSON.parse(raw) as string;
    } catch (e) {
      return raw;
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => setTimeout(resolve, ms));
  }

  /** base64 dataURL → 沙箱临时 PNG → showAssetsCreationDialog 免权限存入相册 */
  private async saveShot(dataUrl: string, shotTitle: string = 'Live2D截图', okMsg: string = '截图已保存到相册'): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const comma = dataUrl.indexOf(',');
    if (comma < 0) {
      throw new Error('dataUrl 缺少逗号');
    }
    const helper = new util.Base64Helper();
    const bytes = helper.decodeSync(dataUrl.substring(comma + 1));
    const dir = `${ctx.filesDir}/screenshots`;
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    const shotPath = `${dir}/shot_${Date.now()}.png`;
    const file = fs.openSync(shotPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    fs.writeSync(file.fd, buffer);
    fs.closeSync(file.fd);
    // 免权限存相册：系统弹窗让用户确认
    const srcUri = fileUri.getUriFromPath(shotPath);
    const ph = photoAccessHelper.getPhotoAccessHelper(ctx);
    const configs: photoAccessHelper.PhotoCreationConfig[] = [{
      title: shotTitle,
      fileNameExtension: 'png',
      photoType: photoAccessHelper.PhotoType.IMAGE,
    }];
    const desUris = await ph.showAssetsCreationDialog([srcUri], configs);
    if (desUris.length === 0) {
      promptAction.showToast({ message: '已取消保存', duration: 1200 });
      return;
    }
    const srcFile = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
    const desFile = fs.openSync(desUris[0], fs.OpenMode.READ_WRITE);
    fs.copyFileSync(srcFile.fd, desFile.fd);
    fs.closeSync(srcFile.fd);
    fs.closeSync(desFile.fd);
    promptAction.showToast({ message: okMsg, duration: 1500 });
  }

  /** 舞台背景：加载当前设置（管理入口在设置页，此处只负责渲染） */
  private async initStageBg(): Promise<void> {
    const opt = await backgroundService.loadCurrent();
    this.stageBg = opt;
    this.refreshBgSrc();
  }

  /** 背景版本变化（设置页修改背景）：重读并刷新舞台背景层 */
  private onBgVersionChange(): void {
    this.initStageBg();
  }

  /** 根据当前 stageBg 刷新背景图渲染路径 */
  private refreshBgSrc(): void {
    this.bgImageSrc = this.stageBg.type === 'image' && this.stageBg.fileName !== ''
      ? `file://${backgroundService.getDir()}/${this.stageBg.fileName}`
      : '';
  }

  private onDbVersionChange(): void {
    Logger.info(TAG, '模型库版本变化，刷新列表: %{public}d', this.modelDbVersion);
    this.refreshAll();
  }

  /** 速览页跳转：重置筛选确保目标模型可见，再加载并选中（卡槽自动跟随） */
  private onOverviewSelect(): void {
    if (this.overviewSelectPath === '') {
      return;
    }
    this.versionFilter = 'all';
    this.selectedCategoryKey = '';
    this.favoriteOnly = false;
    AppStorage.setOrCreate('modelsVersion', 'all');
    this.selectedPath = this.overviewSelectPath;
    this.loadModels();
  }

  /** 数据库变更后先刷新分类（重置失效筛选项），再加载列表，避免用旧分类查询 */
  private async refreshAll(): Promise<void> {
    await this.loadCategories();
    await this.loadModels();
  }

  private async loadModels(): Promise<void> {
    try {
      // 版本筛选独立；分类筛选仅按分类名过滤（同名分类跨版本只显示一次）
      let version: string | undefined = this.versionFilter === 'all' ? undefined : this.versionFilter;
      const unCategorized = this.selectedCategoryKey === CAT_UNASSIGNED;
      let category: string | undefined;
      if (this.selectedCategoryKey !== '' && !unCategorized) {
        category = this.selectedCategoryKey;
      }
      const list = await modelStore.queryModels({
        version,
        favoriteOnly: this.favoriteOnly,
        unCategorizedOnly: unCategorized,
        category,
      });
      this.models = list;
      // P2-1：列表恢复时清空状态提示，避免“暂无符合条件的模型”残留
      this.statusMsg = '';
      if (list.length > 0) {
        const current = list.find((item: ModelRecord) => item.entryPath === this.selectedPath);
        this.selectModel(current ?? list[0], 1, false);
      } else {
        this.selectedPath = '';
        this.statusMsg = '暂无符合条件的模型';
      }
    } catch (e) {
      Logger.error(TAG, '加载模型列表失败: %{public}s', JSON.stringify(e));
    }
  }

  private async loadCategories(): Promise<void> {
    try {
      this.categoryEntries = await modelStore.listCategoryEntries();
      // 分类被删除/重命名后，重置已失效的筛选项
      if (this.selectedCategoryKey !== '' && this.selectedCategoryKey !== CAT_UNASSIGNED) {
        let found = false;
        for (const entry of this.categoryEntries) {
          if (entry.name === this.selectedCategoryKey) {
            found = true;
            break;
          }
        }
        if (!found) {
          this.selectedCategoryKey = '';
        }
      }
    } catch (e) {
      Logger.error(TAG, '加载分类失败: %{public}s', JSON.stringify(e));
    }
  }

  /** 分类菜单选项（按钮弹窗形式） */
  private categoryMenuOptions(): MenuElement[] {
    const options: MenuElement[] = [
      {
        value: '全部分类',
        action: () => {
          this.selectedCategoryKey = '';
          this.loadModels();
        },
      },
    ];
    // 同名分类（C2/C3 各一条）去重：只显示一次
    const seen: string[] = [];
    for (const entry of this.categoryEntries) {
      if (seen.indexOf(entry.name) >= 0) {
        continue;
      }
      seen.push(entry.name);
      options.push({
        value: entry.name,
        action: () => {
          this.selectedCategoryKey = entry.name;
          this.loadModels();
        },
      });
    }
    // “未分类”固定在菜单最下面
    options.push({
      value: '未分类',
      action: () => {
        this.selectedCategoryKey = CAT_UNASSIGNED;
        this.loadModels();
      },
    });
    return options;
  }

  /** 版本筛选菜单 */
  private versionMenuOptions(): MenuElement[] {
    return [
      {
        value: '全部',
        action: () => {
          this.versionFilter = 'all';
          AppStorage.setOrCreate('modelsVersion', 'all');
          this.loadModels();
        },
      },
      {
        value: 'Cubism 2',
        action: () => {
          this.versionFilter = 'cubism2';
          AppStorage.setOrCreate('modelsVersion', 'cubism2');
          this.loadModels();
        },
      },
      {
        value: 'Cubism 3',
        action: () => {
          this.versionFilter = 'cubism3';
          AppStorage.setOrCreate('modelsVersion', 'cubism3');
          this.loadModels();
        },
      },
    ];
  }

  /** 分类按钮文案（含版本标记） */
  private categoryLabel(): string {
    if (this.selectedCategoryKey === '') {
      return '分类 ▾';
    }
    if (this.selectedCategoryKey === CAT_UNASSIGNED) {
      return '分类：未分类';
    }
    return `分类：${this.selectedCategoryKey}`;
  }

  /** 版本按钮文案 */
  private versionLabel(): string {
    if (this.versionFilter === 'cubism2') {
      return 'C2 ▾';
    }
    if (this.versionFilter === 'cubism3') {
      return 'C3 ▾';
    }
    return '全部 ▾';
  }

  /** 卡槽显示名：取最后一个 / 之后的内容（C2 分组路径过长时可读性更好） */
  private shortName(item: ModelRecord): string {
    const name = item.displayName === '' ? item.roleName : item.displayName;
    const idx = name.lastIndexOf('/');
    return idx >= 0 ? name.substring(idx + 1) : name;
  }

  /** 标题行显示当前选中模型名（与卡槽名称一致） */
  private currentModelName(): string {
    if (this.selectedPath === '') {
      return '模型展示';
    }
    const current = this.models.find((item: ModelRecord) => item.entryPath === this.selectedPath);
    return current ? this.shortName(current) : '模型展示';
  }

  /** 标题行第二行：当前模型的自定义分类（无分类显示“未分类”） */
  private currentCategoryName(): string {
    if (this.selectedPath === '') {
      return '';
    }
    const current = this.models.find((item: ModelRecord) => item.entryPath === this.selectedPath);
    if (!current) {
      return '';
    }
    const cat = current.category.trim();
    return cat === '' ? '未分类' : cat;
  }

  /** 首页按钮切换版本（P0-1）：AppStorage 变化统一走这里 */
  private onExternalVersion(): void {
    if (this.externalVersion === 'cubism2' || this.externalVersion === 'cubism3') {
      this.versionFilter = this.externalVersion;
      this.loadModels();
    }
  }

  /** 复制记录并替换部分字段（ArkTS 不支持对象展开，用构造器重建） */
  private cloneWith(record: ModelRecord, patch: Record<string, Object>): ModelRecord {
    const copy = new ModelRecord(
      record.version,
      record.groupName,
      record.roleName,
      record.entryPath,
      record.displayName,
      record.category,
      record.actions,
    );
    copy.id = record.id;
    copy.favorite = record.favorite;
    copy.broken = record.broken;
    copy.createdAt = record.createdAt;
    copy.canvasW = record.canvasW;
    copy.canvasH = record.canvasH;
    if (patch['favorite'] !== undefined) {
      copy.favorite = patch['favorite'] as number;
    }
    return copy;
  }

  /** 卡槽卡片宽：4 个并列（可视宽 - 左右 padding 16 - 3*间距 30）/ 4；下限 72 保证小屏仍可辨认 */
  private slotCardWidth(): number {
    return Math.max(72, Math.round((this.slotViewWidth - 46) / 4));
  }

  /** 卡槽滚动：选中项停靠左起第 2 个可见位（左侧只露 1 个，右侧露出 2 个更靠近拇指）；
   *  偏移 = idx*(宽+间距) - (宽+间距)，首/末项超出范围自动停靠边缘 */
  private scrollSlotToIndex(idx: number, animate: boolean): void {
    const pitch = this.slotCardWidth() + 10;
    const target = idx * pitch - pitch;
    if (animate) {
      this.slotScroller.scrollTo({
        xOffset: target,
        yOffset: 0,
        animation: { duration: 260, curve: Curve.FastOutSlowIn },
      });
    } else {
      this.slotScroller.scrollTo({ xOffset: target, yOffset: 0 });
    }
  }

  /** 缩放值限幅（双指误操作保护） */
  private clampViewScale(v: number): number {
    return Math.min(this.VIEW_SCALE_MAX, Math.max(this.VIEW_SCALE_MIN, v));
  }

  /** 当前活动层的视角缩放（双指手势读写按活动层，不跨层共享） */
  private curViewScale(): number {
    return this.activeWebIndex === 0 ? this.viewScale0 : this.viewScale1;
  }

  /** 当前活动层的视角 X 偏移 */
  private curViewX(): number {
    return this.activeWebIndex === 0 ? this.viewX0 : this.viewX1;
  }

  /** 当前活动层的视角 Y 偏移 */
  private curViewY(): number {
    return this.activeWebIndex === 0 ? this.viewY0 : this.viewY1;
  }

  /** 写入指定层的视角 */
  private setLayerView(layer: number, scale: number, x: number, y: number): void {
    if (layer === 0) {
      this.viewScale0 = scale;
      this.viewX0 = x;
      this.viewY0 = y;
    } else {
      this.viewScale1 = scale;
      this.viewX1 = x;
      this.viewY1 = y;
    }
  }

  /** 写入当前活动层的视角 */
  private setCurView(scale: number, x: number, y: number): void {
    this.setLayerView(this.activeWebIndex, scale, x, y);
  }

  /** 两指当前距离（onTouch 双指模式自算缩放用） */
  private twoFingerDist(touches: TouchObject[]): number {
    if (touches.length < 2) {
      return 0;
    }
    const dx = touches[0].x - touches[1].x;
    const dy = touches[0].y - touches[1].y;
    return Math.sqrt(dx * dx + dy * dy);
  }

  /** 两指中心 X（onTouch 双指模式自算 X 偏移用） */
  private twoFingerCX(touches: TouchObject[]): number {
    return touches.length >= 2 ? (touches[0].x + touches[1].x) / 2 : 0;
  }

  /** 两指中心 Y（onTouch 双指模式自算 Y 偏移用） */
  private twoFingerCY(touches: TouchObject[]): number {
    return touches.length >= 2 ? (touches[0].y + touches[1].y) / 2 : 0;
  }

  /** 恢复某模型的记忆视角到指定 Web 层（preferences 按模型 id 存储，无记录则默认视角）。
   *  切换动画时对进场层（inactive）应用，滑入瞬间视角即正确，不出现跳变 */
  private async applyViewFor(record: ModelRecord, layer: number): Promise<void> {
    let s = 1;
    let x = 0;
    let y = 0;
    try {
      const saved = await themeManager.getPref<string>(`view_${record.id}`, '');
      if (saved !== '') {
        const obj = JSON.parse(saved) as Record<string, number>;
        const ns = Number(obj['s']);
        if (!Number.isNaN(ns)) {
          s = ns;
        }
        // 旧数据中的 r（旋转）已弃用，直接忽略
        const nx = Number(obj['x']);
        if (!Number.isNaN(nx)) {
          x = nx;
        }
        const ny = Number(obj['y']);
        if (!Number.isNaN(ny)) {
          y = ny;
        }
      }
    } catch (e) {
      Logger.warn(TAG, '视角记录解析失败，使用默认: %{public}s', JSON.stringify(e));
    }
    s = this.clampViewScale(s);
    // 平滑过渡到记忆视角（与胶片切换动画重叠，视觉不跳变）
    this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
      this.setLayerView(layer, s, x, y);
    });
  }

  /** 保存当前活动层展示的模型视角到 preferences（手势结束/切换前/重置时调用） */
  private saveCurrentView(): void {
    const record = this.models.find((item: ModelRecord) => item.entryPath === this.selectedPath);
    if (!record) {
      return;
    }
    const payload = JSON.stringify({
      s: this.curViewScale(),
      x: this.curViewX(),
      y: this.curViewY(),
    });
    themeManager.putPref(`view_${record.id}`, payload);
  }

  /** 重置当前活动层模型视角为默认并保存（双指轻点 / 右上角重置按钮触发） */
  private resetView(): void {
    this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
      this.setCurView(1, 0, 0);
    });
    this.saveCurrentView();
    promptAction.showToast({ message: '视角已重置', duration: 1000 });
  }

  /** 选择模型：双层舞台胶片切换。animate=false 用于列表初始加载（直接展示当前层） */
  private selectModel(record: ModelRecord, direction: number = 1, animate: boolean = true): void {
    if (this.stageSwitching && animate) {
      return;
    }
    // 重复点击当前选中模型：不触发胶片切换（避免舞台空翻），但保留视角兜底
    if (animate && record.entryPath === this.selectedPath) {
      return;
    }
    // 切换前先保存当前活动层（旧模型）的视角，再更新选中
    this.saveCurrentView();
    this.selectedPath = record.entryPath;
    this.pendingRecord = record;
    if (!animate) {
      // 初始/列表刷新：直接加载到当前层，不做切换动画；新模型视角应用到当前显示层
      this.applyViewFor(record, this.activeWebIndex).catch((e: Error) => {
        Logger.warn(TAG, '视角恢复失败: %{public}s', JSON.stringify(e));
      });
      this.loadStageFor(this.activeWebIndex, record);
      // 初始加载完成前即预加载下一个模型到非活动层（左滑时右侧画面已就绪）
      this.preloadByDirection(1);
    } else {
      // 胶片切换：新层从对侧切入，旧层平移出
      const inactive = 1 - this.activeWebIndex;
      // 进场层滑入前应用目标模型记忆的视角（该层独立持有视角，不继承旧层，避免切页跳动）
      this.applyViewFor(record, inactive).catch((e: Error) => {
        Logger.warn(TAG, '视角恢复失败: %{public}s', JSON.stringify(e));
      });
      this.stageDirection = direction;
      this.stageSwitching = true;
      // 非活动层若已预加载该模型则直接使用（画面已就绪）
      if (this.layerEntryPaths[inactive] !== record.entryPath || !this.webLoadedFlags[inactive]) {
        this.loadStageFor(inactive, record);
      }
      const outX = direction >= 0 ? -this.stageWidth : this.stageWidth;
      const inX = direction >= 0 ? this.stageWidth : -this.stageWidth;
      // 非拖动触发（卡槽点击）：新层还没跟手，先瞬移到对侧；拖动触发则保持当前跟手位置
      const curInactiveX = inactive === 0 ? this.stage0TranslateX : this.stage1TranslateX;
      if (Math.abs(curInactiveX) < 1) {
        if (inactive === 0) {
          this.stage0TranslateX = inX;
          this.stage0Opacity = 1;
        } else {
          this.stage1TranslateX = inX;
          this.stage1Opacity = 1;
        }
      }
      this.getUIContext().animateTo({ duration: 420, curve: Curve.EaseInOut }, () => {
        if (this.activeWebIndex === 0) {
          this.stage0TranslateX = outX;
          this.stage0Opacity = 0;
          this.stage1TranslateX = 0;
          this.stage1Opacity = 1;
        } else {
          this.stage1TranslateX = outX;
          this.stage1Opacity = 0;
          this.stage0TranslateX = 0;
          this.stage0Opacity = 1;
        }
      });
      // 动画结束：切换当前层，旧层复位隐藏
      setTimeout(() => {
        this.activeWebIndex = inactive;
        this.stageSwitching = false;
        if (inactive === 0) {
          this.stage1TranslateX = 0;
          this.stage1Opacity = 0;
        } else {
          this.stage0TranslateX = 0;
          this.stage0Opacity = 0;
        }
        // 切换完成：预加载下一个模型到新的非活动层
        this.preloadByDirection(direction);
      }, 440);
    }
    // 卡槽跟随：初始加载/速览跳转直接定位（不从头滑过中间项），交互切换平滑滚动；
    // 选中项停靠左起第 2 个可见位（右侧 2 个在拇指顺手区；首/末项自动停靠边缘）
    const idx = this.models.findIndex((item: ModelRecord) => item.entryPath === record.entryPath);
    if (idx >= 0) {
      if (this.immersive) {
        // 沉浸模式卡槽未挂载（if 条件隐藏）：只记录目标索引，退出沉浸后由 onImmersiveChange 补滚动
        this.pendingSlotScrollIdx = idx;
      } else {
        setTimeout(() => {
          this.scrollSlotToIndex(idx, animate);
        }, animate ? 60 : 120);
      }
    }
  }

  /** 舞台左右滑动切换模型：delta=1 下一个，delta=-1 上一个（循环） */
  private selectRelative(delta: number): void {
    if (this.models.length === 0) {
      return;
    }
    let idx = this.models.findIndex((item: ModelRecord) => item.entryPath === this.selectedPath);
    if (idx < 0) {
      idx = 0;
    }
    idx = (idx + delta + this.models.length) % this.models.length;
    this.selectModel(this.models[idx], delta);
  }

  /** 按方向预加载相邻模型到非活动层：direction=1 预加载下一个，-1 预加载上一个 */
  private preloadByDirection(direction: number): void {
    if (this.models.length < 2) {
      return;
    }
    const idx = this.models.findIndex((item: ModelRecord) => item.entryPath === this.selectedPath);
    if (idx < 0) {
      return;
    }
    const target = this.models[(idx + direction + this.models.length) % this.models.length];
    const preloadIndex = 1 - this.activeWebIndex;
    // 已预加载同模型则跳过
    if (this.layerEntryPaths[preloadIndex] === target.entryPath && this.webLoadedFlags[preloadIndex]) {
      return;
    }
    Logger.info(TAG, '预加载相邻模型(%{public}d): %{public}s/%{public}s',
      direction, target.version, target.entryPath);
    this.loadStageFor(preloadIndex, target);
  }

  /** 在指定层加载模型：c3 用 group/role；c2 用完整 model 路径（与渲染页校验规则一致） */
  private loadStageFor(webIndex: number, record: ModelRecord): void {
    this.layerEntryPaths[webIndex] = record.entryPath;
    const pathParam = encodeURIComponent(record.entryPath);
    // P1-7：舞台使用 30fps；C2 舞台附带动作列表供轮播（P1-2）
    let url: string;
    if (record.version === 'cubism3') {
      // hi=1：舞台高分辨率画布（DPR≤4），双指放大保持清晰；卡片缩略图不传 hi 走默认省电
      url = `${BASE_URL}/render3.html?path=${pathParam}&fps=30&hi=1`;
    } else {
      const actionsParam = encodeURIComponent((record.actions ?? []).join(','));
      // cw/ch：.moc 画布尺寸（原项目 canvas_w/h 语义），渲染页按此比例 contain 适配
      url = `${BASE_URL}/render.html?path=${pathParam}&cw=${record.canvasW}&ch=${record.canvasH}` +
        `&fps=30&actions=${actionsParam}&hi=1`;
    }
    Logger.info(TAG, '舞台加载: %{public}s', url);
    // 同类型页面已就绪：走 JS 换模型（页面/引擎常驻，避免整页重载空白）
    if (this.webLoadedFlags[webIndex] && record.version === this.pageVersionFlags[webIndex] &&
      this.pageVersionFlags[webIndex] !== '') {
      // C2 画布尺寸与当前页不一致时无法原位重建，回退整页加载
      if (record.version === 'cubism2' &&
        (record.canvasW !== this.canvasWFlags[webIndex] || record.canvasH !== this.canvasHFlags[webIndex])) {
        this.webLoadedFlags[webIndex] = false;
        this.pageVersionFlags[webIndex] = record.version;
        this.canvasWFlags[webIndex] = record.canvasW;
        this.canvasHFlags[webIndex] = record.canvasH;
        this.loadUrlFallback(webIndex, url);
        return;
      }
      const jsPath = JSON.stringify(record.entryPath);
      let script = `window.__switchModel && window.__switchModel(${jsPath})`;
      if (record.version === 'cubism2') {
        const actionsJs = JSON.stringify((record.actions ?? []).join(','));
        script = `window.__switchModel && window.__switchModel(${jsPath}, ${actionsJs})`;
      }
      this.webControllers[webIndex].runJavaScript(script).catch(() => {
        Logger.warn(TAG, 'JS 换模型失败，回退整页加载');
        this.webLoadedFlags[webIndex] = false;
        this.loadUrlFallback(webIndex, url);
      });
    } else {
      // 首次加载或跨类型切换：整页加载
      this.webLoadedFlags[webIndex] = false;
      this.pageVersionFlags[webIndex] = record.version;
      this.canvasWFlags[webIndex] = record.canvasW;
      this.canvasHFlags[webIndex] = record.canvasH;
      this.loadUrlFallback(webIndex, url);
      // 模型就绪检测：未收到 l2d-ready 标题则重试整页加载（真机首次 WebGL 可能静默失败）。
      // C2/C3 首载都可能静默失败，重试窗口统一 1 秒，否则模型要等 4-5 秒才显示
      this.fullLoadPendingFlags[webIndex] = true;
      this.fullLoadRetriesFlags[webIndex] = 0;
      this.scheduleFullLoadCheck(webIndex, url);
    }
  }

  private scheduleFullLoadCheck(webIndex: number, url: string): void {
    if (this.fullLoadTimers[webIndex] >= 0) {
      clearTimeout(this.fullLoadTimers[webIndex]);
    }
    // C2/C3 首载都可能静默失败，统一 1 秒快速重试
    const retryDelay = 1000;
    this.fullLoadTimers[webIndex] = setTimeout(() => {
      if (this.fullLoadPendingFlags[webIndex] && this.fullLoadRetriesFlags[webIndex] < 2) {
        this.fullLoadRetriesFlags[webIndex] += 1;
        Logger.warn(TAG, '舞台模型未就绪（未收到 l2d-ready），重试 %{public}d 次',
          this.fullLoadRetriesFlags[webIndex]);
        try {
          this.webControllers[webIndex].loadUrl(url);
        } catch (e) {
          Logger.warn(TAG, '舞台重试 loadUrl 失败: %{public}s', JSON.stringify(e));
        }
        this.scheduleFullLoadCheck(webIndex, url);
      }
    }, retryDelay);
  }

  private loadUrlFallback(webIndex: number, url: string): void {
    try {
      this.webControllers[webIndex].loadUrl(url);
    } catch (e) {
      // Web 组件重建时首次 loadUrl 可能报 17100001，onControllerAttached 会兜底重试
      Logger.warn(TAG, '舞台首调失败（等待兜底重试）: %{public}s', JSON.stringify(e));
    }
  }

  /** 下拉提示文案：仅跟随当前模型收藏状态，下拉过程中固定不变（快速操作时不产生迷惑） */
  private pullHintText(): string {
    const record = this.models.find((item: ModelRecord) => item.entryPath === this.selectedPath);
    const isFav = record ? record.favorite === 1 : false;
    return isFav ? '下拉取消收藏' : '下拉收藏';
  }

  // ── 动作手动切换（F1-1）──

  /** 当前选中模型的动作列表（C2 存模型-json 路径、C3 存 stem，与引擎 __playAction 入参一致） */
  private currentModelActions(): string[] {
    const record = this.models.find((item: ModelRecord) => item.entryPath === this.selectedPath);
    return record && record.actions ? record.actions : [];
  }

  /** 动作展示名：C2 路径取末段去扩展名（motions/happy.mtn → happy），C3 已是 stem */
  private actionDisplayName(name: string): string {
    let base = name;
    const slash = base.lastIndexOf('/');
    if (slash >= 0) {
      base = base.substring(slash + 1);
    }
    const dot = base.lastIndexOf('.');
    if (dot > 0) {
      base = base.substring(0, dot);
    }
    return base;
  }

  /**
   * 动作按钮展示名：去掉全部动作名的公共前缀，只展示差异化部分（xxx_001/xxx_002 → 001/002）。
   * 兜底：动作数 <=1、公共前缀 <2 字符、或某名称去掉前缀后为空 → 保留完整展示名。
   */
  private strippedActionName(name: string): string {
    const all = this.currentModelActions().map((a: string) => this.actionDisplayName(a));
    if (all.length <= 1) {
      return this.actionDisplayName(name);
    }
    // 计算最长公共前缀
    let prefix: string = all[0];
    for (let i = 1; i < all.length; i++) {
      let j = 0;
      const maxLen = Math.min(prefix.length, all[i].length);
      while (j < maxLen && prefix.charCodeAt(j) === all[i].charCodeAt(j)) {
        j++;
      }
      prefix = prefix.substring(0, j);
      if (prefix.length === 0) {
        break;
      }
    }
    // 前缀过短或去掉后为空：裁剪没有意义，保留原名
    if (prefix.length < 2) {
      return this.actionDisplayName(name);
    }
    const rest = this.actionDisplayName(name).substring(prefix.length);
    if (rest.length === 0) {
      return this.actionDisplayName(name);
    }
    return rest;
  }

  /** 手动播放动作：引擎播放后自动暂停轮播，避免 5 秒后被轮播覆盖；胶囊记录选中态 */
  private playActionViaJs(name: string): void {
    const js = `window.__playAction && window.__playAction(${JSON.stringify(name)});` +
      `window.__stopRotation && window.__stopRotation()`;
    this.webControllers[this.activeWebIndex].runJavaScript(js).catch(() => {
      Logger.warn(TAG, '动作播放失败: %{public}s', name);
    });
    this.rotationOn = false;
    this.activeAction = name;
  }

  /** 轮播开关：恢复/暂停当前模型动作轮播（恢复时清空手动选中态） */
  private toggleRotation(): void {
    this.rotationOn = !this.rotationOn;
    const js = this.rotationOn
      ? 'window.__startRotation && window.__startRotation()'
      : 'window.__stopRotation && window.__stopRotation()';
    this.webControllers[this.activeWebIndex].runJavaScript(js).catch(() => {
      Logger.warn(TAG, '轮播切换失败');
    });
    if (this.rotationOn) {
      this.activeAction = '';
    }
  }

  // ── 舞台沉浸模式（U1-1）──

  /** 沉浸切换监听：进入时记录当前选中索引；退出时等卡槽重新挂载后补滚动对齐 */
  private onImmersiveChange(): void {
    if (this.immersive) {
      const idx = this.models.findIndex((item: ModelRecord) => item.entryPath === this.selectedPath);
      if (idx >= 0) {
        this.pendingSlotScrollIdx = idx;
      }
    } else if (this.pendingSlotScrollIdx >= 0) {
      const idx = this.pendingSlotScrollIdx;
      this.pendingSlotScrollIdx = -1;
      // List 重新挂载后 ForEach 布局需要时间，延迟再滚动
      setTimeout(() => {
        this.scrollSlotToIndex(idx, false);
      }, 120);
    }
  }

  /** 双击切换沉浸：进入时收起动作面板并顶部短显退出提示 */
  private toggleImmersive(): void {
    this.immersive = !this.immersive;
    if (this.immersive) {
      this.showActionPanel = false;
      this.immersiveHintVisible = true;
      if (this.immersiveHintTimer >= 0) {
        clearTimeout(this.immersiveHintTimer);
      }
      this.immersiveHintTimer = setTimeout(() => {
        this.immersiveHintVisible = false;
        this.immersiveHintTimer = -1;
      }, 2200);
    }
  }

  private async toggleFavorite(record: ModelRecord): Promise<void> {
    const next = record.favorite === 1 ? 0 : 1;
    await modelStore.updateFavorite(record.id, next);
    // P1-1：本地即时刷新（不依赖数据库重查），避免 UI 状态滞后
    this.models = this.models.map((item: ModelRecord) => {
      return item.id === record.id ? this.cloneWith(item, { 'favorite': next }) : item;
    });
    promptAction.showToast({
      message: next === 1 ? '已收藏' : '已取消收藏',
      duration: 1200,
    });
  }

  /** 单模型删除：确认后物理删除文件 + 数据库记录 + 缩略图（P1-4） */
  private confirmDelete(record: ModelRecord): void {
    this.getUIContext().showAlertDialog({
      title: '删除模型',
      message: `确定删除「${record.displayName}」？模型文件将被物理删除，不可恢复。`,
      primaryButton: {
        value: '取消',
        action: () => {
        },
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#C12F1C',
        action: () => {
          this.deleteModel(record).catch((e: Error) => {
            Logger.error(TAG, '删除模型失败: %{public}s', JSON.stringify(e));
            promptAction.showToast({ message: '删除失败', duration: 1500 });
          });
        },
      },
    });
  }

  private async deleteModel(record: ModelRecord): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await importService.removeModelFiles(ctx, record);
    await modelStore.deleteModel(record.id);
    // 递增全局版本号：通知模型页/速览页刷新
    bumpModelDbVersion();
    promptAction.showToast({ message: '模型已删除', duration: 1200 });
  }

  /** 横向卡槽卡片：纯缩略图 + 版本徽章（无卡片外壳），选中主题色发光浮起 */
  @Builder
  slotCard(item: ModelRecord) {
    Stack({ alignContent: Alignment.TopEnd }) {
      Image(`file://${thumbnailService.thumbPath(item.entryPath)}`)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .backgroundColor('#F1F3F5')
      Text(item.version === 'cubism3' ? 'C3' : 'C2')
        .fontSize(10)
        .fontColor(Color.White)
        .backgroundColor(item.version === 'cubism3' ? this.theme().accent : '#6B3FD4')
        .borderRadius(4)
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .margin(6)
    }
    .width('100%')
    .height(88)
    .borderRadius(12)
    // 选中态：2px 浅色主题描边（仅选中显示）+ 浅色光晕 + 放大上浮（弱化深色外框）
    .border({
      width: this.selectedPath === item.entryPath ? 2 : 0,
      color: `#80${this.theme().accentSoft.substring(1)}`,
    })
    // 关键：圆角裁剪子内容，否则缩略图仍是方角（ArkUI borderRadius 不自动裁剪）
    .clip(true)
    .shadow(this.selectedPath === item.entryPath
      ? { radius: 14, color: `#66${this.theme().accentSoft.substring(1)}`, offsetY: 4 }
      : { radius: 5, color: '#26000000', offsetY: 2 })
    .scale({
      x: this.selectedPath === item.entryPath ? 1.06 : 1.0,
      y: this.selectedPath === item.entryPath ? 1.06 : 1.0,
    })
    .translate({ y: this.selectedPath === item.entryPath ? -6 : 0 })
    .animation({ duration: 180, curve: Curve.EaseOut })
    .onClick(() => {
      // 卡槽点击：按目标模型相对当前选中在列表中的位置决定切入方向——
      // 选左边（索引更小）的模型时新层从左侧切入，选右边则从右侧切入
      const curIdx = this.models.findIndex((m: ModelRecord) => m.entryPath === this.selectedPath);
      const newIdx = this.models.findIndex((m: ModelRecord) => m.entryPath === item.entryPath);
      this.selectModel(item, newIdx < curIdx ? -1 : 1);
    })
  }

  /**
   * 舞台 Web 层（胶片切换的双层之一）：0/1 由 webIndex 区分。
   * 6 个回调对两层完全相同，只有落点数组不同；状态值（透明度/位移/视角）按层用三元选择。
   */
  @Builder
  stageWeb(webIndex: number) {
    Stack() {
      Web({ src: 'about:blank', controller: this.webControllers[webIndex] })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(true)
        .onControllerAttached(() => {
          // Web 组件重建/首次关联时若已有待选模型则立即加载（首调 17100001 兜底）
          if (this.pendingRecord && !this.webLoadedFlags[webIndex]) {
            this.loadStageFor(webIndex, this.pendingRecord);
          }
        })
        .onPageEnd(() => {
          // 页面加载完成：后续同类型模型切换走 JS 换模型
          this.webLoadedFlags[webIndex] = true;
        })
        .onTitleReceive((event) => {
          // 渲染页模型就绪后标题变为 l2d-ready，确认首次加载真正成功
          if (event?.title === 'l2d-ready') {
            this.fullLoadPendingFlags[webIndex] = false;
            if (this.fullLoadTimers[webIndex] >= 0) {
              clearTimeout(this.fullLoadTimers[webIndex]);
              this.fullLoadTimers[webIndex] = -1;
            }
          }
        })
        .onInterceptRequest((event) => {
          if (!event) {
            return null;
          }
          return assetServer.handle(event.request);
        })
        .onErrorReceive((event) => {
          Logger.error(TAG, '舞台错误: %{public}s', event?.error.getErrorInfo() ?? '');
        })
        .onConsole((event) => {
          Logger.info(TAG, '舞台 console: %{public}s', event?.message?.getMessage() ?? '');
          return false;
        })
        .width('100%')
        .height('100%')
        // ArkWeb 默认白底：显式透明，让舞台主题色/立绘透明区域透出
        .backgroundColor(Color.Transparent)
        .opacity(webIndex === 0 ? this.stage0Opacity : this.stage1Opacity)
        .translate({ x: webIndex === 0 ? this.stage0TranslateX : this.stage1TranslateX })
    }
    .width('100%')
    .height('100%')
    // 视角变换容器（scale/translate 挂外层，切页动画保留在内部 Web 上）
    .scale({
      x: webIndex === 0 ? this.viewScale0 : this.viewScale1,
      y: webIndex === 0 ? this.viewScale0 : this.viewScale1,
    })
    .translate({
      x: webIndex === 0 ? this.viewX0 : this.viewX1,
      y: webIndex === 0 ? this.viewY0 : this.viewY1,
    })
  }

  /** 舞台悬浮圆钮：32 圆形 + 主题描边 + 轻阴影 + 按压缩放，定位由调用方 position 指定 */
  @Builder
  stageFloatButton(icon: Resource, x: number, y: number, action: () => void) {
    Column() {
      SymbolGlyph(icon)
        // 重置视角图标偏复杂，字号略小（按资源 id 判断，避免 Resource 对象引用比较不可靠）
        .fontSize(icon.id === $r('sys.symbol.arrow_counterclockwise').id ? 11 : 15)
        .fontColor([this.theme().accent])
    }
    .width(32)
    .height(32)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.theme().card)
    .borderRadius(16)
    .border({ width: 1, color: `#59${this.theme().accent.substring(1)}` })
    .shadow({ radius: 8, color: '#26000000', offsetY: 2 })
    // 数值坐标定位（markAnchor/align 实测均不可靠；按钮 32 + 边距 14 = 46）
    .position({ x, y })
    // 阻止触摸穿透到舞台 onTouch（避免误触发翻页/下拉）
    .onTouch((e: TouchEvent) => {
      e.stopPropagation();
    })
    .stateStyles({
      pressed: { .scale({ x: 0.92, y: 0.92 }) },
    })
    .onClick(action)
  }

  build() {
    Column() {
      // 标题行（沉浸模式隐藏，让舞台占满全屏）
      if (!this.immersive) {
        Row() {
          Column() {
            Text(this.currentModelName())
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.theme().titleColor)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            // 第二行：当前模型分类（accent 圆点 + 灰色小字，弱化处理不抢标题视觉）
            Row({ space: 5 }) {
              Text('●')
                .fontSize(7)
                .fontColor(this.theme().accent)
                .margin({ top: 1 })
              Text(this.currentCategoryName())
                .fontSize(11)
                .fontColor(this.theme().textSecondary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .alignItems(VerticalAlign.Center)
            .margin({ top: 2 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Blank()
          // 版本筛选（全部/C2/C3，首页按钮可驱动）
          Text(this.versionLabel())
            .fontSize(12)
            .fontColor(this.versionFilter === 'all' ? this.theme().textSecondary : this.theme().accent)
            .height(26)
            .textAlign(TextAlign.Center)
            .padding({ left: 10, right: 10 })
            .backgroundColor(this.theme().border)
            .borderRadius(8)
            .margin({ right: 8 })
            .bindMenu(this.versionMenuOptions())
          // 右上角分类筛选（始终显示，无分类时菜单只有“全部分类”）
          Text(this.categoryLabel())
            .fontSize(12)
            .fontColor(this.selectedCategoryKey === '' ? this.theme().textSecondary : this.theme().accent)
            .height(26)
            .textAlign(TextAlign.Center)
            .padding({ left: 10, right: 10 })
            .backgroundColor(this.theme().border)
            .borderRadius(8)
            .margin({ right: 8 })
            .bindMenu(this.categoryMenuOptions())
          // 收藏筛选（★ 高亮 = 只看收藏，位于分类下拉右侧）
          Text(this.favoriteOnly ? '★' : '☆')
            .fontSize(14)
            .fontColor(this.favoriteOnly ? '#8A5C00' : this.theme().textSecondary)
            .width(30)
            .height(26)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.theme().border)
            .borderRadius(8)
            .margin({ right: 8 })
            .onClick(() => {
              this.favoriteOnly = !this.favoriteOnly;
              this.loadModels();
            })
          // 重新生成缺失缩略图（导入失败/超时跳过后可手动重试）
          Text('⟳')
            .fontSize(16)
            .fontColor(this.theme().accent)
            .width(28)
            .height(26)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.theme().border)
            .borderRadius(8)
            .margin({ right: 8 })
            .onClick(() => {
              const current = AppStorage.get<number>('thumbRegenTick') ?? 0;
              AppStorage.setOrCreate('thumbRegenTick', current + 1);
              promptAction.showToast({ message: '正在重新生成缺失缩略图…', duration: 1200 });
            })
          Text(`${this.models.length} 个`)
            .fontSize(12)
            .fontColor(this.theme().textSecondary)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 4 })
      }

      // 下拉收藏提示：仅下拉手势期间显示，灰色、不随舞台移动
      if (!this.immersive && this.pullHintVisible) {
        Row({ space: 6 }) {
          Text('↓')
            .fontSize(16)
            .fontColor(this.theme().textSecondary)
          Text(this.pullHintText())
            .fontSize(12)
            .fontColor(this.theme().textSecondary)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: 2, bottom: 4 })
      }

      // 常驻 Live2D 舞台：置顶（卡槽点击模型后加载）
      // 舞台叠层：alignContent 保持默认（TopStart），子组件用各自 .align() 定位——
      // 一旦设置 alignContent，子组件 align() 会失效（此前导致按钮被推到左上角）
      Stack() {
        // 背景层：自定义图片固定铺满舞台。不随视角变换/切换动画（全局背景，切模型不变），
        // 触摸穿透到外层 onTouch，不参与手势判定
        if (this.bgImageSrc !== '') {
          Image(this.bgImageSrc)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .backgroundColor(Color.Transparent)
            .hitTestBehavior(HitTestMode.None)
        }

        // 第 0 层：视角变换容器（scale/rotate/translate 挂外层，切页动画保留在内部 Web 上）
        this.stageWeb(0)

        // 第 1 层（胶片切换的目标层）：视角变换容器
        this.stageWeb(1)

        // 沉浸退出提示：顶部居中短显（按主题色描边卡片）
        if (this.immersive && this.immersiveHintVisible) {
          Text('按返回键退出沉浸')
            .fontSize(12)
            .fontColor(this.theme().accent)
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .backgroundColor(this.theme().card)
            .borderRadius(12)
            .border({ width: 1, color: `#59${this.theme().accent.substring(1)}` })
            // 顶部居中：markAnchor 实测不生效，改用数值定位（onAreaChange 记录自身宽度，减半居中）
            .onAreaChange((_oldValue: Area, newValue: Area) => {
              this.immersiveHintW = newValue.width as number;
            })
            .position({ x: (this.stageWidth - this.immersiveHintW) / 2, y: 16 })
            .transition(TransitionEffect.OPACITY.animation({ duration: 220 }))
        }

        // 动作入口按钮：沉浸模式隐藏；点击打开底部动作面板（右下角悬浮）
        if (!this.immersive) {
          this.stageFloatButton($r('sys.symbol.list_bullet'), this.stageWidth - 46, this.stageHeight - 46, () => {
            this.showActionPanel = !this.showActionPanel;
          })
        }

        // 重置视角按钮：右上角悬浮（非沉浸时显示）；沉浸模式可用双指轻点舞台重置
        if (!this.immersive) {
          this.stageFloatButton($r('sys.symbol.arrow_counterclockwise'), this.stageWidth - 46, 14, () => {
            this.resetView();
          })
        }

        // 截图按钮：右上角悬浮（↺ 正下方）；只截舞台+背景+模型，不含悬浮层
        if (!this.immersive) {
          this.stageFloatButton($r('sys.symbol.camera'), this.stageWidth - 46, 56, () => {
            this.captureStage();
          })
        }

        // 仅模型截图按钮：右上角悬浮（相机正下方）；导出透明底模型 PNG，不带背景
        if (!this.immersive) {
          this.stageFloatButton($r('sys.symbol.person'), this.stageWidth - 46, 98, () => {
            this.captureStage(true);
          })
        }

        // 动作面板：动作列表 + 轮播开关（底部滑入）
        if (this.showActionPanel) {
          Column({ space: 10 }) {
            Row() {
              Text('动作')
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.theme().textPrimary)
              Blank()
              Text(this.rotationOn ? '轮播：开' : '轮播：关')
                .fontSize(12)
                .fontColor(this.rotationOn ? this.theme().accent : this.theme().textSecondary)
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .backgroundColor(this.rotationOn ? `#1A${this.theme().accent.substring(1)}` : this.theme().border)
                .borderRadius(10)
                .onClick(() => {
                  this.toggleRotation();
                })
              // 背景入口：背景管理已迁移到设置页，此处不再提供
              Text('✕')
                .fontSize(16)
                .fontColor(this.theme().textSecondary)
                .padding({ left: 8 })
                .onClick(() => {
                  this.showActionPanel = false;
                })
            }
            .width('100%')

            if (this.currentModelActions().length === 0) {
              Text('该模型没有可用的动作')
                .fontSize(12)
                .fontColor(this.theme().textSecondary)
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 8, bottom: 8 })
            } else {
              // 动作过多时面板高度封顶（30%），列表区内部滚动；3 列定宽，超长省略号 + 长按看全名
              Scroll() {
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.currentModelActions(), (name: string) => {
                    Text(this.strippedActionName(name))
                      .fontSize(13)
                      .fontColor(this.activeAction === name ? Color.White : this.theme().textPrimary)
                      .width('32%')
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .textAlign(TextAlign.Center)
                      .padding({ left: 6, right: 6, top: 6, bottom: 6 })
                      .backgroundColor(this.activeAction === name ? this.theme().accent : this.theme().border)
                      .borderRadius(10)
                      .margin({ right: '1.3%', bottom: 8 })
                      .stateStyles({
                        pressed: { .scale({ x: 0.94, y: 0.94 }) },
                      })
                      .onClick(() => {
                        this.playActionViaJs(name);
                      })
                      // 长按查看完整动作名（3 列定宽截断后的信息兜底）
                      .gesture(
                        LongPressGesture()
                          .onAction(() => {
                            promptAction.showToast({
                              message: this.actionDisplayName(name),
                              duration: 1500,
                            });
                          })
                      )
                  }, (name: string) => name)
                }
                .width('100%')
              }
              // 仅动作多时封顶 20%（相对舞台）内部滚动；动作少时高度 = 内容高度（一行）
              .constraintSize({ maxHeight: '20%' })
              .scrollBar(BarState.Auto)
              .edgeEffect(EdgeEffect.Spring)
            }
          }
          .width('100%')
          .padding(14)
          // 25% 不透明 + 毛玻璃：比入口按钮更透，舞台模型清晰透出，blur 保证文字可读
          .backgroundColor(`#40${this.theme().card.substring(1)}`)
          .backdropBlur(24)
          .borderRadius(14)
          .border({ width: 1, color: `#59${this.theme().accent.substring(1)}` })
          .shadow({ radius: 16, color: '#40000000', offsetY: 4 })
          // 贴底定位：align 实测不生效，改数值坐标（面板底 = 舞台底，即卡槽上方）；高度自测修正
          .onAreaChange((_oldValue: Area, newValue: Area) => {
            this.actionPanelH = newValue.height as number;
          })
          .position({ x: 0, y: Math.max(0, this.stageHeight - this.actionPanelH) })
          .onTouch((e: TouchEvent) => {
            e.stopPropagation();
          })
          .transition(
            TransitionEffect.OPACITY
              .combine(TransitionEffect.translate({ y: 24 }))
              .animation({ duration: 200, curve: Curve.FastOutSlowIn })
          )
        }
      }
      .layoutWeight(1)
      .width('100%')
      // 舞台底边向上收 30（与卡槽上移对齐，避免遮挡）；沉浸时贴底占满
      .margin({ bottom: this.immersive ? 0 : 30 })
      // 下拉收藏手势：舞台整体下移跟手（translate 不影响布局与命中区域）
      .translate({ y: this.stageTranslateY })
      // 保险：即使定位估算偏差，悬浮按钮也不被舞台边界裁剪（卡槽 List 在其下，
      // 正常定位不重叠；仅在首帧尺寸回填前可能越界，裁掉会彻底看不见）
      .clip(false)
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        this.stageWidth = newValue.width as number;
        this.stageHeight = newValue.height as number;
      })
      // 左滑下一个、右滑上一个：触摸位移水平且超过阈值时切换
      .onTouch((event: TouchEvent) => {
        // 动作面板打开时：点按面板外区域直接关闭（无遮罩变暗），不触发收藏/翻页；
        // 面板内触摸已 stopPropagation，不会走到这里
        if (this.showActionPanel) {
          if (event.type === TouchType.Down) {
            this.showActionPanel = false;
          }
          return;
        }
        if (event.type === TouchType.Down) {
          // 手指计数 +1；第二根及以上手指按下：进入多指模式，记录双指起始快照（距离/中心点/视角），
          // 取消进行中的单指手势状态
          this.activePointers++;
          if (this.activePointers >= 2) {
            this.multiTouch = true;
            this.dragActive = false;
            this.pullingDown = false;
            this.pullHintVisible = false;
            this.pinchStartDist = this.twoFingerDist(event.touches);
            this.pinchStartScale = this.curViewScale();
            this.panStartCX = this.twoFingerCX(event.touches);
            this.panStartCY = this.twoFingerCY(event.touches);
            this.panStartX = this.curViewX();
            this.panStartY = this.curViewY();
            this.panStartTime = Date.now();
            this.getUIContext().animateTo({ duration: 150, curve: Curve.EaseInOut }, () => {
              this.stageTranslateY = 0;
              if (this.activeWebIndex === 0) {
                this.stage0TranslateX = 0;
                this.stage1TranslateX = 0;
                this.stage1Opacity = 0;
              } else {
                this.stage1TranslateX = 0;
                this.stage0TranslateX = 0;
                this.stage0Opacity = 0;
              }
            });
            return;
          }
          this.touchStartX = event.touches[0].x;
          this.touchStartY = event.touches[0].y;
          this.tapDownTime = Date.now();
          this.dragActive = false;
          this.pullingDown = false;
        } else if (event.type === TouchType.Move) {
          // 双指操作进行中：自己计算缩放（两指距离比）与 X/Y 偏移（两指中心位移），单指翻页/下拉逻辑全部让位
          if (this.multiTouch) {
            if (event.touches.length >= 2) {
              const curDist = this.twoFingerDist(event.touches);
              let ns = this.curViewScale();
              if (this.pinchStartDist > 0) {
                ns = this.clampViewScale(this.pinchStartScale * (curDist / this.pinchStartDist));
              }
              this.setCurView(ns,
                this.panStartX + (this.twoFingerCX(event.touches) - this.panStartCX),
                this.panStartY + (this.twoFingerCY(event.touches) - this.panStartCY));
            }
            return;
          }
          const touch = event.touches.length > 0 ? event.touches[0] : null;
          if (!touch) {
            return;
          }
          const dx = touch.x - this.touchStartX;
          const dy = touch.y - this.touchStartY;
          // 手势分诊：纵向下拉（向下且纵向为主）→ 收藏手势；水平为主 → 切换手势；其余忽略
          if (!this.dragActive && !this.pullingDown) {
            if (dy > 0 && dy > Math.abs(dx) * 1.2 && dy > 10 && !this.stageSwitching) {
              this.pullingDown = true;
              this.pullHintVisible = true;
            } else if (Math.abs(dx) > Math.abs(dy) * 1.2 && Math.abs(dx) > 10) {
              this.dragActive = true;
            } else {
              return;
            }
          }
          // 下拉收藏模式：舞台整体阻尼跟手，超过阈值后提示就绪
          if (this.pullingDown) {
            const pull = Math.min(dy * this.PULL_DAMPING, this.PULL_MAX);
            this.stageTranslateY = pull;
            return;
          }
          // 拖动中胶卷跟手：当前层跟手，新层从对侧同步跟进
          const dir = dx >= 0 ? -1 : 1;
          this.dragDirection = dir;
          const inactive = 1 - this.activeWebIndex;
          // 非活动层是否已预载“当前拖动方向”的目标模型；方向突变时它仍是旧方向的模型，
          // 跟手显示会露出错误的模型，此时隐藏新层并按新方向补载
          let showIncoming = false;
          const idx = this.models.findIndex((item: ModelRecord) => item.entryPath === this.selectedPath);
          if (idx >= 0) {
            const target = this.models[(idx + dir + this.models.length) % this.models.length];
            if (target) {
              showIncoming = this.layerEntryPaths[inactive] === target.entryPath && this.webLoadedFlags[inactive];
              if (!showIncoming && this.lastDragDirection !== dir &&
                this.layerEntryPaths[inactive] !== target.entryPath) {
                this.loadStageFor(inactive, target);
              }
              // 拖动方向变化：进场层立即应用目标模型记忆的视角（每层独立视角，
              // 避免跟手/切换时带着旧模型视角跳动）。方向不变时不再重复设置
              if (this.lastDragDirection !== dir) {
                this.applyViewFor(target, inactive).catch((e: Error) => {
                  Logger.warn(TAG, '拖动视角预置失败: %{public}s', JSON.stringify(e));
                });
              }
            }
          }
          this.lastDragDirection = dir;
          // 左滑（dir=1）下一个从右侧进场；右滑（dir=-1）上一个从左侧进场
          const inX = dir > 0 ? this.stageWidth : -this.stageWidth;
          if (this.activeWebIndex === 0) {
            this.stage0TranslateX = dx;
            this.stage1TranslateX = showIncoming ? inX + dx : inX;
            this.stage1Opacity = showIncoming ? 1 : 0;
          } else {
            this.stage1TranslateX = dx;
            this.stage0TranslateX = showIncoming ? inX + dx : inX;
            this.stage0Opacity = showIncoming ? 1 : 0;
          }
        } else if (event.type === TouchType.Up) {
          // 手指计数 -1；最后一指抬起后退出多指模式：双指轻点（无位移且时间短）→ 重置视角，否则保存当前视角
          if (this.activePointers > 0) {
            this.activePointers--;
          }
          if (this.multiTouch) {
            if (this.activePointers === 0) {
              this.multiTouch = false;
              const dt = Date.now() - this.panStartTime;
              const moved = Math.abs(this.curViewX() - this.panStartX) > 10 ||
                Math.abs(this.curViewY() - this.panStartY) > 10 ||
                Math.abs(this.curViewScale() - this.pinchStartScale) > 0.05;
              if (dt < 400 && !moved) {
                this.resetView();
              } else {
                this.saveCurrentView();
              }
            }
            return;
          }
          // 抬起时 touches 可能已清空，用 changedTouches 取松开点坐标
          const touch = event.changedTouches.length > 0
            ? event.changedTouches[0] : (event.touches.length > 0 ? event.touches[0] : null);
          if (!touch) {
            return;
          }
          const dx = touch.x - this.touchStartX;
          const dy = touch.y - this.touchStartY;
          // 双击检测：短按且位移极小（不干扰下拉/拖拽手势），300ms 内第二次点按 → 切换沉浸
          const now = Date.now();
          if (!this.pullingDown && !this.dragActive &&
            Math.abs(dx) < 10 && Math.abs(dy) < 10 && (now - this.tapDownTime) < 300) {
            if (now - this.lastTapTime < 300 &&
              Math.abs(touch.x - this.lastTapX) < 30 && Math.abs(touch.y - this.lastTapY) < 30) {
              this.lastTapTime = 0;
              this.toggleImmersive();
            } else {
              this.lastTapTime = now;
              this.lastTapX = touch.x;
              this.lastTapY = touch.y;
            }
          }
          // 下拉手势结束：拉到底（超阈值）则收藏/取消收藏当前模型，随后回弹复位
          if (this.pullingDown) {
            const triggered = dy >= this.PULL_TRIGGER;
            this.pullingDown = false;
            this.pullHintVisible = false;
            this.getUIContext().animateTo({ duration: 250, curve: Curve.EaseInOut }, () => {
              this.stageTranslateY = 0;
            });
            if (triggered) {
              const record = this.models.find((item: ModelRecord) => item.entryPath === this.selectedPath);
              if (record) {
                this.toggleFavorite(record).catch((e: Error) => {
                  Logger.error(TAG, '下拉收藏失败: %{public}s', JSON.stringify(e));
                  promptAction.showToast({ message: '收藏操作失败', duration: 1500 });
                });
              }
            }
            return;
          }
          // 纵向滚动（未激活跟手）：舞台归位，不参与翻页判定
          if (!this.dragActive) {
            this.getUIContext().animateTo({ duration: 250, curve: Curve.EaseInOut }, () => {
              if (this.activeWebIndex === 0) {
                this.stage0TranslateX = 0;
              } else {
                this.stage1TranslateX = 0;
              }
            });
            return;
          }
          // 距离判断：水平位移超过 50vp 且大于垂直位移即翻页（慢速长距离同样生效）
          if (Math.abs(dx) > 50 && Math.abs(dx) > Math.abs(dy) * 1.2) {
            if (dx < 0) {
              this.selectRelative(1);
            } else {
              this.selectRelative(-1);
            }
          } else {
            // 未达阈值：回弹（当前层回原位，新层回对侧隐藏）
            const inactive = 1 - this.activeWebIndex;
            const inX = this.dragDirection >= 0 ? this.stageWidth : -this.stageWidth;
            this.getUIContext().animateTo({ duration: 250, curve: Curve.EaseInOut }, () => {
              if (this.activeWebIndex === 0) {
                this.stage0TranslateX = 0;
                this.stage1TranslateX = inX;
                this.stage1Opacity = 0;
              } else {
                this.stage1TranslateX = 0;
                this.stage0TranslateX = inX;
                this.stage0Opacity = 0;
              }
            });
          }
        } else if (event.type === TouchType.Cancel) {
          // 手势取消（系统中断等）：手指计数清零、多指模式复位，单指状态复位，舞台回原位
          this.activePointers = 0;
          this.multiTouch = false;
          this.pullingDown = false;
          this.pullHintVisible = false;
          this.dragActive = false;
          this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseInOut }, () => {
            this.stageTranslateY = 0;
            if (this.activeWebIndex === 0) {
              this.stage0TranslateX = 0;
              this.stage1TranslateX = 0;
              this.stage1Opacity = 0;
            } else {
              this.stage1TranslateX = 0;
              this.stage0TranslateX = 0;
              this.stage0Opacity = 0;
            }
          });
        }
      })
        .backgroundColor(this.theme().stageBg)
        // 视角缩放/旋转后内容可能超出舞台：裁剪，保持舞台边界整洁
        .clip(true)
        // 双指操作（缩放 / X-Y 偏移 / 双指轻点重置）在下方 onTouch 中自算：
        // 单指翻页/下拉/双击逻辑由 onTouch 独占，不再挂手势系统避免抢占单指事件

      if (!this.immersive && this.statusMsg !== '') {
        Text(this.statusMsg)
          .fontSize(12)
          .fontColor(this.theme().accent)
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 4 })
      }

      // 左右滚动模型卡槽（沉浸模式隐藏）
      if (!this.immersive) {
        List({ scroller: this.slotScroller, space: 10 }) {
          ForEach(this.models, (item: ModelRecord) => {
            ListItem() {
              this.slotCard(item)
            }
            // 4 个并列：卡片宽 = (可视宽 - 左右 padding 16 - 3*间距 18) / 4
            .width(this.slotCardWidth())
          }, (item: ModelRecord) => `${item.entryPath}|${item.favorite}|${this.thumbVersion}`)
        }
        .height(128)
        .width('100%')
        // 底部留白：卡槽整体再上移一点，不贴导航栏
        .padding({ left: 8, right: 8, top: 8, bottom: 22 })
        // 整体上移 30，舞台更大、卡槽更靠上
        .margin({ top: -30 })
        // 关键：关闭裁剪，否则选中卡放大上浮/发光阴影超出 List 区域会被上下切掉
        .clip(false)
        .listDirection(Axis.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .onAreaChange((_oldValue: Area, newValue: Area) => {
          this.slotViewWidth = newValue.width as number;
        })
      }
    }
    .width('100%')
    .height('100%')
    // 沉浸式全屏后顶部避让状态栏，保证标题/筛选行可点
    .padding({ top: 40 })
    .backgroundColor(this.theme().background)
  }
}
