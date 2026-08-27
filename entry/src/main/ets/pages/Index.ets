import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { HdsTabs } from '@kit.UIDesignKit';
import { motion } from '@kit.MultimodalAwarenessKit';
import { promptAction, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { assetServer } from '../services/AssetServer';
import { modelStore } from '../services/ModelStore';
import { modelScanner } from '../services/ModelScanner';
import { thumbnailService } from '../services/ThumbnailService';
import { backgroundService } from '../services/BackgroundService';
import { themeManager, AppTheme } from '../services/ThemeManager';
import { ModelRecord } from '../services/ModelRecord';
import { Logger } from '../common/Logger';
import { resetTaskState, finishTaskState, setTaskState, bumpThumbVersion } from '../common/AppGlobal';
import { ModelsPage } from './ModelsPage';
import { SettingsPage } from './SettingsPage';
import { OverviewPage } from './OverviewPage';

const TAG = 'Index';
const BASE_URL = 'http://127.0.0.1:17890';
/** 缩略图渲染截图的舞台尺寸（竖版立绘比例） */
const THUMB_STAGE_W = 240;
const THUMB_STAGE_H = 420;

@Entry
@Component
struct Index {
  /** 当前 tab：与 HomePage 共用 AppStorage，首页按钮可驱动切换（模型页常亮依赖此值） */
  @StorageLink('currentTabIndex') @Watch('onKeepScreenStateChange') currentIndex: number = 0;
  @StorageProp('themeId') @Watch('onThemeChanged') themeId: string = 'pink';
  @StorageProp('modelDbVersion') @Watch('onDbVersionChange') modelDbVersion: number = 0;
  /** 手动“重新生成缩略图”触发计数（模型页按钮递增，这里监听后重跑队列） */
  @StorageProp('thumbRegenTick') @Watch('onThumbRegenTick') thumbRegenTick: number = 0;
  /** 速览页多选时隐藏底部导航栏 */
  @StorageProp('hideTabBar') @Watch('onHideTabBarChange') hideTabBar: boolean = false;
  /** 舞台沉浸模式（U1-1）：沉浸时隐藏悬浮导航胶囊，退出后恢复 */
  @StorageProp('stageImmersive') @Watch('onImmersiveChange') immersive: boolean = false;
  /** 迷你栏（圆球）是否展开为完整导航 */
  @State isMiniBarExpanded: boolean = false;
  /** 智感握姿：左手握持时导航球在左、胶囊向右展开 */
  @State isLeftHand: boolean = false;
  private thumbController: webview.WebviewController = new webview.WebviewController();
  /** 待生成缩略图的模型队列（后台隐藏 Web 逐个渲染截图） */
  private thumbQueue: ModelRecord[] = [];
  private thumbBusy: boolean = false;
  /** 本次缩略图队列总数（用于进度计算） */
  private thumbTotal: number = 0;
  /** 缩略图任务是否由用户主动触发（完成后需弹提示） */
  private thumbTaskNotify: boolean = false;
  /** 当前缩略图模型加载超时定时器（坏模型不阻塞队列） */
  private thumbTimer: number = -1;
  /** 单个模型截图兜底等待上限：渲染页判定失败（l2d-fail）会立即跳过，这里只兜底“静默卡死” */
  private readonly thumbTimeoutMs: number = 8000;
  /** 隐藏 Web 组件是否已关联 controller（未关联时 webPageSnapshot 会抛 17100001） */
  private thumbControllerReady: boolean = false;

  aboutToAppear(): void {
    // 初始化全局任务状态（设置页进度条读取）
    resetTaskState();
    // 全局服务初始化：资源供给 + 数据层
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    assetServer.init(ctx);
    modelScanner.init(`${ctx.filesDir}/models`);
    thumbnailService.init(`${ctx.filesDir}/thumbnails`);
    backgroundService.init(ctx);
    modelStore.init(ctx).then(() => {
      Logger.info(TAG, '数据层初始化完成');
      // 启动延后缩略图队列：优先保证模型页舞台首屏加载，避免后台 WebGL 抢资源
      setTimeout(() => {
        this.scheduleThumbnailGen();
      }, 5000);
    }).catch((e: Error) => {
      Logger.error(TAG, '数据层初始化失败: %{public}s', JSON.stringify(e));
    });
    // 主题管理器必须先完成（网格密度等偏好读取依赖其 preferences 句柄）
    themeManager.init(ctx).then(() => {
      // 速览网格密度持久化恢复（设置页选择后写入 preferences，启动时还原到 AppStorage）
      return themeManager.getPref<number>('overviewGridCols', 4).then((cols: number) => {
        AppStorage.setOrCreate('overviewGridCols', cols);
      });
    }).catch((e: Error) => {
      Logger.error(TAG, '偏好初始化失败: %{public}s', JSON.stringify(e));
    });
    // 沉浸式适配：状态栏文字颜色跟随主题（深色主题白色、浅色主题深色）
    this.syncSystemBarColor();
    // 智感握姿：查询当前握持/操作手并监听变化，导航球跟随左右切换
    this.initHandedness();
    // 屏幕常亮：启动默认停在模型页，立即应用常亮
    this.applyKeepScreenOn();
  }

  aboutToDisappear(): void {
    try {
      motion.off('holdingHandChanged');
      motion.off('operatingHandChanged');
    } catch (e) {
      Logger.warn(TAG, '注销握姿监听失败: %{public}s', JSON.stringify(e));
    }
  }

  /** 系统返回键：退出沉浸 → 关浮层 → 设置页退回模型页 → 速览多选退出多选，最后才退出 App */
  onBackPress(): boolean {
    // 模型页沉浸模式：返回键退出沉浸（优先级最高，不退出 App）
    if (this.currentIndex === 0 && AppStorage.get<boolean>('stageImmersive') === true) {
      AppStorage.setOrCreate('stageImmersive', false);
      return true;
    }
    if (this.currentIndex === 2 && AppStorage.get<boolean>('settingsChangelogOpen') === true) {
      AppStorage.setOrCreate('settingsChangelogOpen', false);
      return true;
    }
    if (this.currentIndex === 2 && AppStorage.get<boolean>('settingsImportPanelOpen') === true) {
      AppStorage.setOrCreate('settingsImportPanelOpen', false);
      return true;
    }
    if (this.currentIndex === 2 && AppStorage.get<boolean>('settingsCategoryPanelOpen') === true) {
      AppStorage.setOrCreate('settingsCategoryPanelOpen', false);
      return true;
    }
    if (this.currentIndex === 2) {
      // 由设置页自己播退场动画后再切回模型页，避免瞬间跳变
      const tick = AppStorage.get<number>('settingsExitTick') ?? 0;
      AppStorage.setOrCreate('settingsExitTick', tick + 1);
      return true;
    }
    if (this.currentIndex === 1 && AppStorage.get<boolean>('overviewMultiSelect') === true) {
      AppStorage.setOrCreate('overviewMultiSelect', false);
      return true;
    }
    return false;
  }

  private onThemeChanged(): void {
    this.syncSystemBarColor();
  }

  /** 按当前主题设置状态栏/导航条图标颜色，浅色主题用深色图标保证可见 */
  private syncSystemBarColor(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    window.getLastWindow(ctx).then((win: window.Window) => {
      const isDark = this.theme().isDark;
      win.setWindowSystemBarProperties({
        statusBarContentColor: isDark ? '#FFFFFF' : '#000000',
        navigationBarContentColor: isDark ? '#FFFFFF' : '#000000',
      }).catch((err: BusinessError) => {
        Logger.warn(TAG, '设置系统栏颜色失败: %{public}s', JSON.stringify(err));
      });
    }).catch((err: BusinessError) => {
      Logger.warn(TAG, '获取窗口失败: %{public}s', JSON.stringify(err));
    });
  }

  private onDbVersionChange(): void {
    // 导入/扫描后补生成缺失缩略图（等数据库稳定）；仅用户主动触发时才弹完成提示
    setTimeout(() => {
      this.scheduleThumbnailGen();
    }, 1200);
  }

  private onThumbRegenTick(): void {
    this.thumbTaskNotify = true;
    // 手动重新生成：清除历史失败标记，全部重新尝试
    thumbnailService.clearFailed();
    this.scheduleThumbnailGen();
  }

  /** 速览页进入多选时收起导航胶囊，避免遮挡多选操作 */
  private onHideTabBarChange(): void {
    if (this.hideTabBar) {
      this.isMiniBarExpanded = false;
    }
  }

  /** 收集缺失缩略图的模型，启动后台渲染截图队列 */
  private scheduleThumbnailGen(): void {
    modelStore.listModels().then((models) => {
      this.thumbQueue = thumbnailService.listMissing(models);
      this.thumbTotal = this.thumbQueue.length;
      if (this.thumbQueue.length > 0) {
        Logger.info(TAG, '待生成缩略图: %{public}d 个', this.thumbQueue.length);
        this.updateThumbTaskState();
        this.processThumbQueue();
      } else if (this.thumbTaskNotify) {
        // 没有缺失缩略图：任务直接完成
        this.thumbTaskNotify = false;
        finishTaskState();
        promptAction.showToast({ message: '没有缺失的缩略图', duration: 1200 });
      }
    }).catch((e: Error) => {
      Logger.warn(TAG, '收集缺失缩略图失败: %{public}s', JSON.stringify(e));
    });
  }

  /** 把缩略图队列进度同步到 AppStorage（设置页进度条显示） */
  private updateThumbTaskState(): void {
    const done = this.thumbTotal - this.thumbQueue.length;
    setTaskState(`正在生成缩略图 ${done}/${this.thumbTotal}`,
      this.thumbTotal > 0 ? Math.round(done / this.thumbTotal * 100) : -1);
  }

  /** 加载下一个待截图模型到隐藏舞台 */
  private processThumbQueue(): void {
    if (this.thumbBusy || this.thumbQueue.length === 0 || !this.thumbControllerReady) {
      return;
    }
    this.thumbBusy = true;
    const record = this.thumbQueue[0];
    Logger.info(TAG, '缩略图队列: 开始加载 %{public}s/%{public}s', record.version, record.entryPath);
    const pathParam = encodeURIComponent(record.entryPath);
    let url: string;
    if (record.version === 'cubism3') {
      // 缩略图后台渲染 15fps 足够（只取一帧截图），降低与舞台并发时的 GPU 占用
      url = `${BASE_URL}/render3.html?path=${pathParam}&fps=15`;
    } else {
      const actionsParam = encodeURIComponent((record.actions ?? []).join(','));
      url = `${BASE_URL}/render.html?path=${pathParam}&cw=${record.canvasW}&ch=${record.canvasH}` +
        `&fps=15&actions=${actionsParam}`;
    }
    try {
      this.thumbController.loadUrl(url);
      // 超时兜底：模型加载失败（引擎不回调 l2d-ready）时跳过，避免卡死整个队列
      this.thumbTimer = setTimeout(() => {
        Logger.warn(TAG, '缩略图加载超时，跳过: %{public}s/%{public}s',
          record.version, record.entryPath);
        // 打失败标记：下次启动/扫描不再重复等待
        thumbnailService.markFailed(record.entryPath);
        this.finishThumb();
      }, this.thumbTimeoutMs);
    } catch (e) {
      Logger.warn(TAG, '缩略图 loadUrl 失败: %{public}s', JSON.stringify(e));
      thumbnailService.markFailed(record.entryPath);
      this.finishThumb();
    }
  }

  /** 渲染页通知模型就绪（title=l2d-ready）后延时截图 */
  private captureThumb(): void {
    const record = this.thumbQueue.length > 0 ? this.thumbQueue[0] : null;
    if (!record) {
      this.thumbBusy = false;
      return;
    }
    // 渲染页 canvas.toDataURL 导出立绘（preserveDrawingBuffer 保证可读）
    this.thumbController.runJavaScript(`window.__thumbDataUrl ? window.__thumbDataUrl() : ''`)
      .then((dataUrl: string) => {
        // runJavaScript 返回的是 JSON 编码字符串（带引号），需还原
        let real = dataUrl;
        try {
          real = JSON.parse(dataUrl) as string;
        } catch (e) {
          // 非 JSON 时保持原样
        }
        Logger.info(TAG, '缩略图导出长度: %{public}d', real.length);
        if (real && real !== '') {
          thumbnailService.saveBase64(record, real).then(() => {
            this.finishThumb();
          }).catch(() => {
            thumbnailService.markFailed(record.entryPath);
            this.finishThumb();
          });
        } else {
          thumbnailService.markFailed(record.entryPath);
          this.finishThumb();
        }
      }).catch((e: Error) => {
        Logger.warn(TAG, '缩略图 runJavaScript 失败: %{public}s', JSON.stringify(e));
        thumbnailService.markFailed(record.entryPath);
        this.finishThumb();
      });
  }

  private finishThumb(): void {
    if (this.thumbTimer >= 0) {
      clearTimeout(this.thumbTimer);
      this.thumbTimer = -1;
    }
    if (this.thumbQueue.length > 0) {
      this.thumbQueue.shift();
    }
    this.thumbBusy = false;
    Logger.info(TAG, '缩略图队列: 剩余 %{public}d 个', this.thumbQueue.length);
    // 通知模型页网格刷新缩略图
    bumpThumbVersion();
    if (this.thumbQueue.length === 0) {
      // 队列完成：结束任务状态，用户主动触发时弹完成提示
      finishTaskState();
      if (this.thumbTaskNotify) {
        this.thumbTaskNotify = false;
        promptAction.showToast({ message: '缩略图生成完成', duration: 1200 });
      }
      return;
    }
    this.updateThumbTaskState();
    this.processThumbQueue();
  }

  private theme(): AppTheme {
    return themeManager.getById(this.themeId);
  }

  /** 初始化智感握姿：查询最近操作手 + 订阅握持手/操作手变化（设备不支持时保持默认右侧） */
  private initHandedness(): void {
    try {
      // 启动时同步查询最近一次操作手状态（1=左手，2=右手）
      this.applyHandStatus(motion.getRecentOperatingHandStatus());
    } catch (e) {
      Logger.warn(TAG, '查询操作手状态失败: %{public}s', JSON.stringify(e));
    }
    try {
      // 握持手变化（智感握姿主通道，API 20+）
      motion.on('holdingHandChanged', (status: number) => {
        this.applyHoldingStatus(status);
      });
    } catch (e) {
      Logger.warn(TAG, '监听握持手失败: %{public}s', JSON.stringify(e));
    }
    try {
      // 操作手变化（兜底，API 15+）
      motion.on('operatingHandChanged', (status: number) => {
        this.applyHandStatus(status);
      });
    } catch (e) {
      Logger.warn(TAG, '监听操作手失败: %{public}s', JSON.stringify(e));
    }
  }

  /** 应用操作手状态：1=左手、2=右手，未知保持现状 */
  private applyHandStatus(status: number): void {
    if (status === 1) {
      this.setHandSide(true);
    } else if (status === 2) {
      this.setHandSide(false);
    }
  }

  /** 应用握持手状态：1=左手、2=右手、3=双手（默认右侧），未握持/未知保持现状 */
  private applyHoldingStatus(status: number): void {
    if (status === 1) {
      this.setHandSide(true);
    } else if (status === 2 || status === 3) {
      this.setHandSide(false);
    }
  }

  /** 切换导航球所在侧（带过渡动画） */
  private setHandSide(left: boolean): void {
    if (this.isLeftHand === left) {
      return;
    }
    this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
      this.isLeftHand = left;
    });
  }

  /** 展开/收起导航胶囊，带过渡动画 */
  private setNavExpanded(expanded: boolean): void {
    this.getUIContext().animateTo({ duration: 400, curve: Curve.FastOutSlowIn }, () => {
      this.isMiniBarExpanded = expanded;
    });
  }

  /** 沉浸模式监听：进入时收起胶囊（浮层虽已隐藏，但状态需同步，退出后仍是折叠圆球）；沉浸同样保持常亮 */
  private onImmersiveChange(): void {
    if (this.immersive) {
      this.isMiniBarExpanded = false;
    }
    this.applyKeepScreenOn();
  }

  /** 页面切换（currentIndex 变化）时同步屏幕常亮状态 */
  private onKeepScreenStateChange(): void {
    this.applyKeepScreenOn();
  }

  /**
   * 屏幕常亮（防休眠）：仅在模型页（含沉浸模式）保持屏幕点亮，
   * 切到速览/设置页恢复系统自动熄屏，省电。
   */
  private applyKeepScreenOn(): void {
    const shouldKeep = this.currentIndex === 0 || this.immersive;
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    window.getLastWindow(ctx).then((win: window.Window) => {
      return win.setWindowKeepScreenOn(shouldKeep);
    }).catch((err: BusinessError) => {
      Logger.warn(TAG, '设置屏幕常亮失败: %{public}s', JSON.stringify(err));
    });
  }

  @Builder
  tabBuilder() {
    // 常规页签栏完全隐藏：只保留迷你栏（圆球/胶囊）作为唯一导航
    Column()
      .width('100%')
      .height('100%')
      // 空页签栏不拦截点击，内容可直接穿透
      .hitTestBehavior(HitTestMode.None)
  }

  /** 导航浮层：平时折叠成右下角圆球，点开展开为完整导航胶囊 */
  @Builder
  floatingNav() {
    Row({ space: 4 }) {
      if (this.isLeftHand) {
        // 左手握持：圆球在左，胶囊向右展开
        this.navBall()
        if (this.isMiniBarExpanded) {
          this.navButtons()
        }
      } else {
        // 右手握持（默认）：圆球在右，胶囊向左展开
        if (this.isMiniBarExpanded) {
          this.navButtons()
        }
        this.navBall()
      }
    }
    .width(this.isMiniBarExpanded ? 232 : 48)
    .height(48)
    .alignItems(VerticalAlign.Center)
    .borderRadius(24)
    // 半透明 + 背景模糊：胶囊悬浮在舞台/页面上方，透出下方内容（毛玻璃质感）。
    // #33 = 20% 不透明度（比原来 40% 更通透）；Web 舞台是独立合成层，
    // backdropBlur 对 ArkUI 内容生效，对 Web 内容仅半透明色生效（不影响可读性）。
    .backgroundColor(`#33${this.theme().accent.substring(1)}`)
    .backdropBlur(20)
    // 边框：浅色主题描边（accentSoft + 50% 透明度），在浅色内容上淡淡勾勒轮廓，不再深色实线
    .border({ width: 1, color: `#80${this.theme().accentSoft.substring(1)}` })
    .shadow({
      radius: 10,
      color: `#40${this.theme().accentSoft.substring(1)}`,
      offsetY: 4,
    })
    .margin({
      left: this.isLeftHand ? 16 : 0,
      right: this.isLeftHand ? 0 : 16,
      bottom: 28,
    })
    .onClick(() => {
      // 折叠态点击圆球展开；展开态点击胶囊空白处收起
      this.setNavExpanded(!this.isMiniBarExpanded);
    })
  }

  /** 导航圆球（折叠态入口） */
  @Builder
  navBall() {
    Row() {
      SymbolGlyph($r('sys.symbol.square_grid_2x2'))
        .fontSize(20)
        // 胶囊变透明后白图标看不清：改用深色主题文字色
        .fontColor([this.theme().textPrimary])
    }
    .width(48)
    .height(48)
    .justifyContent(FlexAlign.Center)
  }

  /** 胶囊展开态的三个导航按钮 */
  @Builder
  navButtons() {
    Row({ space: 4 }) {
      this.miniTabButton(0, '模型', $r('sys.symbol.person'))
      this.miniTabButton(1, '速览', $r('sys.symbol.square_grid_2x2'))
      this.miniTabButton(2, '设置', $r('sys.symbol.gearshape'))
    }
    .transition(
      TransitionEffect.OPACITY
        .combine(TransitionEffect.translate({ x: -12 }))
        .animation({ duration: 400, curve: Curve.FastOutSlowIn })
    )
  }

  /** 迷你栏展开态的单个导航按钮 */
  @Builder
  miniTabButton(index: number, title: string, icon: Resource) {
    Column({ space: 2 }) {
      SymbolGlyph(icon)
        .fontSize(18)
        // 未选中：深色主题文字（胶囊已变透明，白色在浅背景上看不清）
        .fontColor([this.currentIndex === index ? Color.White : this.theme().textPrimary])
      Text(title)
        .fontSize(10)
        .fontColor(this.currentIndex === index ? Color.White : this.theme().textPrimary)
    }
    .width(56)
    .height(36)
    .justifyContent(FlexAlign.Center)
    .borderRadius(18)
    // 选中：实色主题色底衬（accent），白字对 accent 对比度 4.5+ 达标；
    // 不能用半透明浅色底（白字对比度仅 ~1.5，AGC 自检拦截）；未选中全透明 + 深色文字
    .backgroundColor(this.currentIndex === index ? this.theme().accent : '#00000000')
    .onClick(() => {
      this.currentIndex = index;
      AppStorage.setOrCreate('currentTabIndex', index);
      this.getUIContext().getFocusController().clearFocus();
    })
  }

  build() {
    // 智感握姿：左手对齐左下、右手对齐右下，浮层水平跟随
    Stack({ alignContent: this.isLeftHand ? Alignment.BottomStart : Alignment.BottomEnd }) {
      // index 受控：首页按钮写入 AppStorage 后 Tabs 跟随切换（P0-1）
      HdsTabs({ barPosition: BarPosition.End, index: this.currentIndex }) {
        TabContent() {
          ModelsPage()
        }
        .tabBar(this.tabBuilder())

        TabContent() {
          OverviewPage()
        }
        .tabBar(this.tabBuilder())

        TabContent() {
          SettingsPage()
        }
        .tabBar(this.tabBuilder())
      }
      // 官方页签栏整条隐藏，导航完全交给自定义浮层（圆球/胶囊）
      .barHeight(0)
      .barBackgroundColor(Color.Transparent)
      .scrollable(false)
      // 页面切换过渡时长：避免手势切页瞬间跳变
      .animationDuration(400)
      .backgroundColor(this.theme().background)
      .onChange((index: number) => {
        // 同步回 AppStorage，并清理输入焦点（修复设置页键盘反复弹出）
        this.currentIndex = index;
        AppStorage.setOrCreate('currentTabIndex', index);
        this.getUIContext().getFocusController().clearFocus();
      })

      // 胶囊展开时：覆盖全屏的透明触摸层，触摸（点击/滑动起始）非胶囊区域即收起
      if (this.isMiniBarExpanded && !this.hideTabBar && !this.immersive) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Transparent)
          // 事件穿透：只监听触摸不消费事件，点击/滑动仍正常作用于下层页面
          .hitTestBehavior(HitTestMode.Transparent)
          .onTouch((e: TouchEvent) => {
            if (e.type === TouchType.Down) {
              this.setNavExpanded(false);
            }
          })
      }

      // 自定义导航浮层：左手靠左、右手靠右；多选或沉浸时隐藏
      if (!this.hideTabBar && !this.immersive) {
        this.floatingNav()
      }

      // 缩略图生成用隐藏舞台：屏幕外 + 透明，不干扰主界面
      Web({ src: 'about:blank', controller: this.thumbController })
        .width(THUMB_STAGE_W)
        .height(THUMB_STAGE_H)
        .opacity(0)
        .position({ x: -1000, y: -1000 })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(true)
        .onControllerAttached(() => {
          // controller 与 Web 组件关联完成，队列可以开始
          this.thumbControllerReady = true;
          this.processThumbQueue();
        })
        .onInterceptRequest((event) => {
          if (!event) {
            return null;
          }
          return assetServer.handle(event.request);
        })
        .onTitleReceive((event) => {
          // 渲染页模型就绪后通知截图
          Logger.info(TAG, '缩略图 title: %{public}s (busy=%{public}s)',
            event?.title ?? '', String(this.thumbBusy));
          if (event?.title === 'l2d-ready' && this.thumbBusy) {
            // 模型已就绪：取消超时兜底，进入截图流程
            if (this.thumbTimer >= 0) {
              clearTimeout(this.thumbTimer);
              this.thumbTimer = -1;
            }
            setTimeout(() => {
              this.captureThumb();
            }, 600);
          } else if (event?.title === 'l2d-fail' && this.thumbBusy) {
            // 渲染页内部判定失败：立即跳过，不等兜底超时
            Logger.warn(TAG, '缩略图页面判定失败，跳过');
            if (this.thumbTimer >= 0) {
              clearTimeout(this.thumbTimer);
              this.thumbTimer = -1;
            }
            const record = this.thumbQueue.length > 0 ? this.thumbQueue[0] : null;
            if (record) {
              thumbnailService.markFailed(record.entryPath);
            }
            this.finishThumb();
          }
        })
    }
    // 沉浸式：背景铺满状态栏与导航条区域，内容由内部页面自行避让
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .backgroundColor(this.theme().background)
  }
}
