import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { modelScanner } from '../services/ModelScanner';
import { importService } from '../services/ImportService';
import { modelStore } from '../services/ModelStore';
import { thumbnailService } from '../services/ThumbnailService';
import { backgroundService, StageBgOption } from '../services/BackgroundService';
import { backupService } from '../services/BackupService';
import { THEMES, themeManager, AppTheme } from '../services/ThemeManager';
import { Logger } from '../common/Logger';
import { FileUtil } from '../common/FileUtil';
import { bumpModelDbVersion, bumpBgVersion, setTaskState, finishTaskState } from '../common/AppGlobal';

const TAG = 'SettingsPage';

/**
 * 通用胶囊按钮 @Builder 传参类型（主操作/次级操作共用）。
 * 必须用「对象字面量按引用传递」：ArkUI 中 @Builder 按值传参（布尔/字符串等）不会响应状态变化，
 * 而对象字面量属性变化会触发 @Builder 内 UI 刷新（如确认导入按钮的 enabled 动态开关）。
 */
interface ActionButtonOptions {
  icon: Resource;
  label: string;
  enabled: boolean;
  danger: boolean;
  /** 'primary'=主题渐变主按钮；'outline'=卡片底描边按钮 */
  variant: 'primary' | 'outline';
  height: number;
  width: string;
  action: () => void;
}

/** 更新日志：按日期分块，块内条目带数字序号（最新在上） */
interface ChangelogSection {
  /** 块标题（日期） */
  date: string;
  /** 日期徽标文案（如「今天」），可为空字符串 */
  tag: string;
  /** 改动条目（按序展示，序号自动生成） */
  items: string[];
}

/** 更新日志数据：新版本在前 */
const CHANGELOG: ChangelogSection[] = [
  {
    date: '2026-08-21',
    tag: '今天',
    items: [
      '新增：分类手动排序——设置页分类管理支持上移/下移调整顺序，模型速览与模型页下拉随之重排',
      '移除：桌面卡片功能（我的看板娘收藏轮播卡片）——彻底下线，恢复为纯模型库应用',
      '优化：模型页顶部筛选精简——移除搜索框，收藏筛选移至分类下拉右侧，各按钮高度统一',
      '优化：卡槽全面焕新——去掉卡片外框改纯缩略图悬浮、圆角裁剪、间距加大，选中卡片主题色描边+发光浮起',
      '修复：重复点击已选中的卡槽不再触发舞台空翻（胶片切换）',
    ],
  },
  {
    date: '2026-08-20',
    tag: '',
    items: [
      '移除：隐私/隐藏模式（PIN 私密收藏）——功能逻辑复杂且多 bug，按需彻底下线，恢复为纯模型库应用',
      '新增：备份与恢复——模型+数据一键打包 zip 导出，可随时导入覆盖恢复',
      '新增：模型操作与视角复位——双指缩放/拖动、视角按模型记忆、「↺」一键重置；修复缩放后切模型失效与视角跳动',
      '新增：舞台背景（相册选图，全局生效）+ 舞台截图一键导出，截图复现当前视角、物理像素级清晰度',
      '新增：屏幕常亮（模型页与沉浸模式自动保持亮屏）',
    ],
  },
  {
    date: '2026-08-19',
    tag: '',
    items: [
      '新增：粉紫主题应用图标',
      '优化：动作面板更紧凑透明，按钮纯图标化，动作名自动裁剪公共前缀',
      '优化：卡槽单手可达，一行显示 4 个缩略图，选中项停靠左侧顺手位',
      '优化：沉浸模式自动隐藏悬浮导航胶囊',
      '新增：导入 zip 包后自动将包名填入分类输入框（去掉 .zip 后缀）',
      '修复：「确认导入」按钮选择 zip 后无法点击的问题',
    ],
  },
];

@Component
export struct SettingsPage {
  @State busy: boolean = false;
  @State statusMsg: string = '';
  @State importCategory: string = '';
  /** 页面右滑的起点（用于切换到速览页） */
  private swipeStartX: number = 0;
  private swipeStartY: number = 0;
  /** 分类管理面板状态（P1-3）：全局标记，便于 Index 拦截系统返回键时先关面板 */
  @StorageLink('settingsCategoryPanelOpen') showCategoryPanel: boolean = false;
  /** zip 导入面板状态：交互与分类管理一致（遮罩 + 居中面板），Index 返回键同样拦截 */
  @StorageLink('settingsImportPanelOpen') showImportPanel: boolean = false;
  /** 更新日志弹窗状态：全局标记，Index 返回键优先关闭浮层再退出设置页 */
  @StorageLink('settingsChangelogOpen') showChangelog: boolean = false;
  /** 更新日志中已折叠的日期（3 天之外的日志默认折叠，点击日期行展开） */
  @State foldedDates: string[] = [];
  /** 舞台背景（全局设置，所有模型共用）：color=主题色，image=自定义图片 */
  @State stageBg: StageBgOption = { type: 'color', fileName: '' };
  /** 已导入背景文件列表（缩略图网格用） */
  @State bgImages: string[] = [];
  /** 选中的 zip 包 URI（确认导入时使用） */
  @State importZipUri: string = '';
  /** 选中的 zip 包可读文件名（面板第三行展示） */
  @State importZipName: string = '';
  @State categories: string[] = [];
  @State categoryInput: string = '';
  @State renameTarget: string = '';
  /** 切页退场动画：位移 X / 透明度 */
  @State swipeExitX: number = 0;
  @State swipeExitOpacity: number = 1;
  /** Index 返回键触发设置页退场：每次加 1，Watch 里播动画后切回模型页 */
  @StorageProp('settingsExitTick') @Watch('onSettingsExitTick') settingsExitTick: number = 0;
  /** 模型库统计（P2-6） */
  @State c2Count: number = 0;
  @State c3Count: number = 0;
  /** 关于页统计增强（U3-2）：收藏数 + 磁盘占用 */
  @State favoriteCount: number = 0;
  @State diskUsageLabel: string = '统计中…';
  /** 速览网格密度（U2-2）：3/4/5 列，AppStorage 持久化 */
  @StorageProp('overviewGridCols') gridCols: number = 4;
  @StorageProp('themeId') themeId: string = 'pink';
  @StorageProp('modelDbVersion') @Watch('onDbVersionChange') modelDbVersion: number = 0;
  /** 全局任务状态：进度条显示（Index 缩略图队列 / 本页导入扫描共用） */
  @StorageProp('taskRunning') taskRunning: boolean = false;
  @StorageProp('taskLabel') taskLabel: string = '';
  @StorageProp('taskProgress') taskProgress: number = -1;

  /**
   * 通用胶囊按钮：variant='primary' 用主题渐变主操作；variant='outline' 用卡片底描边次级操作。
   * 两态共用同一套按压回弹/禁用降透明度。
   */
  @Builder
  actionButton(opts: ActionButtonOptions) {
    Button() {
      Row({ space: 8 }) {
        SymbolGlyph(opts.icon)
          .fontSize(20)
          .fontColor([opts.variant === 'outline' ? (opts.danger ? '#C12F1C' : this.theme().accent) : Color.White])
        Text(opts.label)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(opts.variant === 'outline' ? (opts.danger ? '#C12F1C' : this.theme().accent) : Color.White)
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')
    }
    .enabled(opts.enabled)
    .width(opts.width)
    .height(opts.height)
    .borderRadius(opts.height / 2)
    .linearGradient(opts.variant === 'outline'
      ? { angle: 0, colors: [[this.theme().card, 0.0], [this.theme().card, 1.0]] }
      : {
        angle: 135,
        colors: [
          ['#3DFFFFFF', 0.0],
          [opts.danger ? '#C12F1C' : this.theme().accent, 0.3],
          [opts.danger ? '#C12F1C' : this.theme().titleColor, 1.0],
        ],
      })
    .border({
      width: 1,
      color: opts.variant === 'outline' ? (opts.danger ? '#59C12F1C' : `#59${this.theme().accent.substring(1)}`) : '#40FFFFFF',
    })
    .shadow({
      radius: opts.variant === 'outline' ? 8 : 12,
      color: opts.danger ? '#33C12F1C' : `#4D${this.theme().accent.substring(1)}`,
      offsetX: 0,
      offsetY: opts.variant === 'outline' ? 2 : 4,
    })
    .stateStyles({
      pressed: { .scale({ x: 0.96, y: 0.96 }) },
      disabled: { .opacity(0.5) },
    })
    .onClick(opts.action)
  }

  /** 设置页操作卡片：emoji + 标题 + 说明，2 列网格排布（主操作填充主题色，危险操作红色调） */
  @Builder
  actionCard(icon: Resource, title: string, subtitle: string, enabled: boolean, danger: boolean, primary: boolean,
    action: () => void) {
    Column({ space: 4 }) {
      SymbolGlyph(icon)
        .fontSize(28)
        .fontColor([primary ? Color.White : (danger ? '#C12F1C' : this.theme().accent)])
      Text(title)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(primary ? Color.White : (danger ? '#C12F1C' : this.theme().textPrimary))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(subtitle)
        .fontSize(11)
        .fontColor(primary ? '#DDFFFFFF' : this.theme().textSecondary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
    .height(104)
    .borderRadius(16)
    .backgroundColor(primary
      ? this.theme().accent
      : (danger ? '#14C12F1C' : `#14${this.theme().accent.substring(1)}`))
    .border({
      width: 1,
      color: danger ? '#33C12F1C' : `#33${this.theme().accent.substring(1)}`,
    })
    .shadow({
      radius: 10,
      color: '#26000000',
      offsetX: 0,
      offsetY: 3,
    })
    .stateStyles({
      pressed: { .scale({ x: 0.96, y: 0.96 }) },
      disabled: { .opacity(0.5) },
    })
    .onClick(action)
  }

  /** 设置页分组标题（U3-3）：图标 + 标题 + 分隔线 */
  @Builder
  sectionHeader(icon: Resource, title: string) {
    Row({ space: 8 }) {
      SymbolGlyph(icon)
        .fontSize(15)
        .fontColor([this.theme().accent])
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.theme().titleColor)
      Divider()
        .layoutWeight(1)
        .height(1)
        .color(this.theme().border)
        .margin({ left: 4 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 分类管理面板内容（ModalPanelShell 尾随闭包注入：新增/重命名输入 + 分类列表） */
  @Builder
  categoryPanelContent() {
    TextInput({ placeholder: '输入分类名称', text: this.categoryInput })
      .width('100%')
      .height(36)
      .onChange((value: string) => {
        this.categoryInput = value;
      })

    this.actionButton({
      icon: this.renameTarget !== '' ? $r('sys.symbol.square_and_pencil') : $r('sys.symbol.plus'),
      label: this.renameTarget !== '' ? '保存重命名' : '添加分类',
      enabled: true,
      danger: false,
      variant: 'primary',
      height: 38,
      width: '100%',
      action: () => {
        this.submitCategory();
      }
    })
    if (this.renameTarget !== '') {
      this.actionButton({
        icon: $r('sys.symbol.xmark'),
        label: '取消',
        enabled: true,
        danger: false,
        variant: 'outline',
        height: 38,
        width: '100%',
        action: () => {
          this.cancelRename();
        }
      })
    }

    if (this.categories.length === 0) {
      Text('暂无分类，先添加一个吧')
        .fontSize(12)
        .fontColor(this.theme().textSecondary)
    } else {
      List({ space: 8 }) {
        ForEach(this.categories, (name: string) => {
          ListItem() {
            Row({ space: 8 }) {
              // 排序控制：上移/下移（相邻交换 sort，长按拖动暂不做，按钮更稳）
              Text('▲')
                .fontSize(10)
                .fontColor(this.theme().textSecondary)
                .padding(4)
                .backgroundColor(`#1A${this.theme().accent.substring(1)}`)
                .borderRadius(6)
                .onClick(() => {
                  this.moveCategory(name, -1);
                })
              Text('▼')
                .fontSize(10)
                .fontColor(this.theme().textSecondary)
                .padding(4)
                .backgroundColor(`#1A${this.theme().accent.substring(1)}`)
                .borderRadius(6)
                .onClick(() => {
                  this.moveCategory(name, 1);
                })
              Text(name)
                .fontSize(14)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text('重命名')
                .fontSize(12)
                .fontColor(this.theme().accent)
                .backgroundColor(`#1A${this.theme().accent.substring(1)}`)
                .borderRadius(10)
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .onClick(() => {
                  this.startRename(name);
                })
              Text('删除')
                .fontSize(12)
                .fontColor('#C12F1C')
                .backgroundColor('#1AC12F1C')
                .borderRadius(10)
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .onClick(() => {
                  this.confirmDeleteCategory(name);
                })
              Text('删模型')
                .fontSize(12)
                .fontColor('#C12F1C')
                .backgroundColor('#1AC12F1C')
                .borderRadius(10)
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .onClick(() => {
                  this.confirmDeleteCategoryModels(name);
                })
            }
            .width('100%')
            .padding(10)
            .backgroundColor(this.theme().border)
            .borderRadius(8)
          }
        }, (name: string) => name)
      }
      .layoutWeight(1)
      .width('100%')
      .edgeEffect(EdgeEffect.Spring)
    }
  }

  /** zip 导入面板内容（ModalPanelShell 尾随闭包注入：分类输入 + 选包 + 确认导入） */
  @Builder
  importPanelContent() {
    // 第一行：左侧分类输入 + 右侧选取 zip 模型包
    Row({ space: 8 }) {
      TextInput({ placeholder: '输入分类名称（可选）', text: this.importCategory })
        .layoutWeight(1)
        .height(38)
        .onChange((value: string) => {
          this.importCategory = value;
        })
      this.actionButton({
        icon: $r('sys.symbol.folder'),
        label: '选取 zip 模型包',
        enabled: true,
        danger: false,
        variant: 'primary',
        height: 38,
        width: '42%',
        action: () => {
          this.pickZipFile().catch((e: Error) => {
            Logger.error(TAG, 'zip 选取异常: %{public}s', JSON.stringify(e));
          });
        }
      })
    }
    .width('100%')

    // 第二行：选中的 zip 包（居中展示）
    Text(this.importZipName === '' ? '未选择 zip 包' : this.importZipName)
      .fontSize(14)
      .fontColor(this.importZipName === '' ? this.theme().textSecondary : this.theme().accent)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .textAlign(TextAlign.Center)
      .width('100%')

    // 第三行：确认导入（enabled 按对象引用传递，选完 zip 后按钮才会解除禁用）
    this.actionButton({
      icon: $r('sys.symbol.checkmark'),
      label: '确认导入',
      enabled: this.importZipUri !== '' && !this.busy,
      danger: false,
      variant: 'primary',
      height: 38,
      width: '100%',
      action: () => {
        this.confirmImportZip().catch((e: Error) => {
          Logger.error(TAG, 'zip 导入异常: %{public}s', JSON.stringify(e));
        });
      }
    })
  }

  /** 更新日志面板内容（ModalPanelShell 尾随闭包注入：按日期分块，块内条目数字序号，内容超长可滚动） */
  @Builder
  changelogPanelContent() {
    Scroll() {
      Column({ space: 16 }) {
        ForEach(CHANGELOG, (section: ChangelogSection) => {
          Column({ space: 8 }) {
            Row({ space: 8 }) {
              Text(section.date)
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.theme().titleColor)
              if (section.tag !== '') {
                Text(section.tag)
                  .fontSize(10)
                  .fontColor(Color.White)
                  .backgroundColor(this.theme().accent)
                  .borderRadius(8)
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              }
              Blank()
              // 3 天之外的日志可折叠：显示展开/收起标记
              if (this.isBeyond3Days(section.date)) {
                Text(this.isFolded(section.date) ? '▸' : '▾')
                  .fontSize(12)
                  .fontColor(this.theme().textSecondary)
                  .padding({ left: 6, right: 4 })
              }
            }
            .width('100%')
            .onClick(() => {
              this.toggleFolded(section.date);
            })

            // 折叠时隐藏该日期下的条目，展开后恢复
            if (!this.isFolded(section.date)) {
              ForEach(section.items, (item: string, index: number) => {
                Row({ space: 8 }) {
                  Text(`${index + 1}`)
                    .fontSize(11)
                    .fontColor(this.theme().accent)
                    .backgroundColor(`#1A${this.theme().accent.substring(1)}`)
                    .borderRadius(9)
                    .width(18)
                    .height(18)
                    .textAlign(TextAlign.Center)
                    .margin({ top: 1 })
                  Text(item)
                    .fontSize(13)
                    .fontColor(this.theme().textPrimary)
                    .lineHeight(19)
                    .layoutWeight(1)
                }
                .width('100%')
                .alignItems(VerticalAlign.Top)
              }, (item: string, index: number) => `${section.date}_${index}`)
            }
          }
          .width('100%')
        }, (section: ChangelogSection) => section.date)
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.Start)
    }
    .layoutWeight(1)
    .width('100%')
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring)
  }

  aboutToAppear(): void {
    this.refreshMeta();
    this.initFoldedDates();
    this.initStageBg();
  }

  /** 日志日期距今天的天数（今天为 0） */
  private diffDaysFromToday(dateStr: string): number {
    const parts = dateStr.split('-');
    const d = new Date(parseInt(parts[0]), parseInt(parts[1]) - 1, parseInt(parts[2]));
    const now = new Date();
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    return Math.floor((today.getTime() - d.getTime()) / 86400000);
  }

  /** 该日期是否属于「3 天之外」（距今天 >= 3 天） */
  private isBeyond3Days(dateStr: string): boolean {
    return this.diffDaysFromToday(dateStr) >= 3;
  }

  /** 初始化折叠：3 天之外的日志块默认折叠 */
  private initFoldedDates(): void {
    this.foldedDates = [];
    for (const section of CHANGELOG) {
      if (this.isBeyond3Days(section.date)) {
        this.foldedDates.push(section.date);
      }
    }
  }

  /** 该日期块当前是否处于折叠状态 */
  private isFolded(dateStr: string): boolean {
    return this.foldedDates.includes(dateStr);
  }

  /** 点击日期行切换折叠/展开（仅 3 天之外的可折叠） */
  private toggleFolded(dateStr: string): void {
    if (!this.isBeyond3Days(dateStr)) {
      return;
    }
    if (this.isFolded(dateStr)) {
      const idx = this.foldedDates.indexOf(dateStr);
      this.foldedDates.splice(idx, 1);
    } else {
      this.foldedDates.push(dateStr);
    }
  }

  private onDbVersionChange(): void {
    // 导入/删除/分类变更后刷新统计与分类列表
    this.refreshMeta();
  }

  private async refreshMeta(): Promise<void> {
    try {
      // ArkTS 不支持解构声明，顺序 await 各统计项
      this.categories = await modelStore.listCategories();
      this.c2Count = await modelStore.countByVersion('cubism2');
      this.c3Count = await modelStore.countByVersion('cubism3');
      const favorites = await modelStore.queryModels({ favoriteOnly: true });
      this.favoriteCount = favorites.length;
      // 磁盘占用：遍历模型目录统计（异步，期间显示"统计中…"）
      this.diskUsageLabel = '统计中…';
      this.diskUsageLabel = await this.computeDiskUsageLabel();
    } catch (e) {
      Logger.error(TAG, '加载统计失败: %{public}s', JSON.stringify(e));
    }
  }

  /** 统计模型目录占用空间（递归子目录，格式化输出） */
  private async computeDiskUsageLabel(): Promise<string> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const root = `${ctx.filesDir}/models`;
    let total = 0;
    try {
      const entries = await fs.listFile(root, { recursion: true });
      for (const rel of entries) {
        try {
          const st = fs.statSync(`${root}/${rel}`);
          total += st.size;
        } catch (e) {
          // 单文件统计失败忽略（删除竞态等）
        }
      }
    } catch (e) {
      Logger.warn(TAG, '磁盘占用统计失败: %{public}s', JSON.stringify(e));
      return '--';
    }
    return this.formatBytes(total);
  }

  private formatBytes(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    const kb = bytes / 1024;
    if (kb < 1024) {
      return `${kb.toFixed(1)} KB`;
    }
    const mb = kb / 1024;
    if (mb < 1024) {
      return `${mb.toFixed(1)} MB`;
    }
    return `${(mb / 1024).toFixed(2)} GB`;
  }

  /** 切换速览网格密度：写 AppStorage（速览页即时生效）+ preferences 持久化 */
  private setGridCols(cols: number): void {
    AppStorage.setOrCreate('overviewGridCols', cols);
    themeManager.putPref('overviewGridCols', cols);
  }

  private theme(): AppTheme {
    return themeManager.getById(this.themeId);
  }

  /** 舞台背景：加载当前设置与已导入列表 */
  private async initStageBg(): Promise<void> {
    this.stageBg = await backgroundService.loadCurrent();
    this.bgImages = backgroundService.listImages();
  }

  /** 应用背景：即时持久化，并递增全局版本号通知模型页刷新舞台背景层 */
  private setStageBg(opt: StageBgOption): void {
    this.stageBg = opt;
    backgroundService.saveCurrent(opt);
    bumpBgVersion();
  }

  /** 从相册导入新背景并立即应用 */
  private async importBg(): Promise<void> {
    try {
      const fileName = await backgroundService.importFromGallery();
      if (fileName === '') {
        return;
      }
      this.bgImages = backgroundService.listImages();
      this.setStageBg({ type: 'image', fileName });
      promptAction.showToast({ message: '背景已应用', duration: 1200 });
    } catch (e) {
      Logger.error(TAG, '导入背景失败: %{public}s', JSON.stringify(e));
      promptAction.showToast({ message: '导入失败，请重试', duration: 1500 });
    }
  }

  /** 删除指定背景文件；若为当前使用中则回退主题色 */
  private deleteBg(fileName: string): void {
    this.getUIContext().showAlertDialog({
      title: '删除背景',
      message: '删除后该背景将从列表中移除，舞台恢复主题色。',
      primaryButton: {
        value: '取消',
        action: () => {
        },
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#C12F1C',
        action: () => {
          const removed = backgroundService.removeImage(fileName);
          if (!removed) {
            promptAction.showToast({ message: '删除失败，请重试', duration: 1500 });
            return;
          }
          this.bgImages = backgroundService.listImages();
          if (this.stageBg.type === 'image' && this.stageBg.fileName === fileName) {
            this.setStageBg({ type: 'color', fileName: '' });
          }
        },
      },
    });
  }

  /** 设置页右滑进入速览页（分类管理面板打开时不响应） */
  private onRootTouch(event: TouchEvent): void {
    if (this.showCategoryPanel || this.showImportPanel) {
      return;
    }
    if (event.type === TouchType.Down) {
      this.swipeStartX = event.touches[0].x;
      this.swipeStartY = event.touches[0].y;
    } else if (event.type === TouchType.Up) {
      const touch = event.changedTouches.length > 0
        ? event.changedTouches[0] : (event.touches.length > 0 ? event.touches[0] : null);
      if (!touch) {
        return;
      }
      const dx = touch.x - this.swipeStartX;
      const dy = touch.y - this.swipeStartY;
      // 仅当水平是主方向时才切页（页面内纵向滚动时手稍偏不会误触发）
      if (dx > 60 && dx > Math.abs(dy) * 1.2) {
        // 先播退场动画再切页，避免瞬间跳变
        this.switchPageWithAnim(1);
      }
    }
  }

  /** 页面退场动画结束后切换 tab（页面向右滑出，与速览页滑动手势一致） */
  private switchPageWithAnim(target: number): void {
    this.getUIContext().animateTo({ duration: 280, curve: Curve.EaseInOut }, () => {
      this.swipeExitX = 50;
      this.swipeExitOpacity = 0;
    });
    setTimeout(() => {
      AppStorage.setOrCreate('currentTabIndex', target);
      this.swipeExitX = 0;
      this.swipeExitOpacity = 1;
    }, 300);
  }

  /** Index 返回键触发：设置页播退场动画后切回模型页（面板已在 Index 侧关闭） */
  private onSettingsExitTick(): void {
    this.switchPageWithAnim(0);
  }

  private async rescan(): Promise<void> {
    if (this.busy) {
      return;
    }
    try {
      this.busy = true;
      this.setTask('正在扫描模型目录…', -1);
      this.statusMsg = '正在扫描模型目录…';
      const scan = await modelScanner.scanAndPersist();
      this.statusMsg = `扫描完成：共 ${scan.total} 个，新增 ${scan.added} 条`;
      bumpModelDbVersion();
      this.finishTask(`扫描完成：共 ${scan.total} 个，新增 ${scan.added} 条`);
    } catch (e) {
      Logger.error(TAG, '扫描异常: %{public}s', JSON.stringify(e));
      this.statusMsg = '扫描失败';
      this.finishTask('扫描失败');
    } finally {
      this.busy = false;
    }
  }

  private async importSamples(): Promise<void> {
    if (this.busy) {
      return;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      this.busy = true;
      this.setTask('正在导入内置示例…', -1);
      this.statusMsg = '正在导入内置示例…';
      const importResult = await importService.importSamples(ctx, this.importCategory.trim());
      this.statusMsg = `内置示例导入完成：新增 ${importResult.added} 个模型`;
      bumpModelDbVersion();
      this.finishTask(`内置示例导入完成：新增 ${importResult.added} 个模型`);
    } catch (e) {
      Logger.error(TAG, '内置示例导入异常: %{public}s', JSON.stringify(e));
      this.statusMsg = '内置示例导入失败';
      this.finishTask('内置示例导入失败');
    } finally {
      this.busy = false;
    }
  }

  /** 打开 zip 导入面板：分类输入 + 选取压缩包 + 确认导入 */
  private openImportPanel(): void {
    this.importCategory = '';
    this.importZipUri = '';
    this.importZipName = '';
    this.showImportPanel = true;
  }

  private closeImportPanel(): void {
    this.importCategory = '';
    this.importZipUri = '';
    this.importZipName = '';
    this.showImportPanel = false;
  }

  /** 选取 zip 模型包：记录 URI 并提取可读文件名供面板展示 */
  private async pickZipFile(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const documentPicker = new picker.DocumentViewPicker(ctx);
    try {
      const result = await documentPicker.select({
        maxSelectNumber: 1,
        fileSuffixFilters: ['.zip'],
      });
      if (result.length === 0) {
        return;
      }
      this.importZipUri = result[0];
      this.importZipName = FileUtil.displayName(result[0], '已选择 zip 模型包');
      // 用模型包名（去 .zip 后缀）预填分类名称输入框
      this.importCategory = this.categoryFromZipName(result[0]);
    } catch (e) {
      Logger.error(TAG, '选取 zip 失败: %{public}s', JSON.stringify(e));
      promptAction.showToast({ message: '选取失败，请重试', duration: 1200 });
    }
  }

  /** 从 zip 文件名提取默认分类名：解码并去掉 .zip 后缀；URI 无文件名段时保持原输入 */
  private categoryFromZipName(uri: string): string {
    const noQuery = uri.split('?')[0];
    const seg = decodeURIComponent(noQuery.substring(noQuery.lastIndexOf('/') + 1));
    if (seg === '') {
      return this.importCategory;
    }
    const lower = seg.toLowerCase();
    return lower.endsWith('.zip') ? seg.substring(0, seg.length - 4) : seg;
  }

  /** 确认导入：关闭弹窗后走原有导入流程（进度条/状态显示不变） */
  private async confirmImportZip(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (this.importZipUri === '') {
      promptAction.showToast({ message: '请先选择 zip 模型包', duration: 1200 });
      return;
    }
    // 关闭面板会清空面板状态，先捕获本次导入所需的分类与 URI
    const category = this.importCategory.trim();
    const zipUri = this.importZipUri;
    this.closeImportPanel();
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.busy = true;
    this.setTask('准备导入…', -1);
    this.statusMsg = '准备导入…';
    try {
      const importResult = await importService.importFromZip(ctx, zipUri, category, (msg: string) => {
        this.statusMsg = msg;
        this.setTask(msg, -1);
      });
      this.statusMsg = importResult.version === 'none'
        ? '未在压缩包中识别到模型文件'
        : `导入完成：新增 ${importResult.added} 个模型`;
      bumpModelDbVersion();
      this.finishTask(this.statusMsg);
    } catch (e) {
      Logger.error(TAG, '导入异常: %{public}s', JSON.stringify(e));
      this.statusMsg = '导入失败，请检查压缩包格式';
      this.finishTask('导入失败，请检查压缩包格式');
    } finally {
      this.busy = false;
    }
  }

  /** 启动任务：写入 AppStorage 供进度条显示（委托公共函数） */
  private setTask(label: string, progress: number): void {
    setTaskState(label, progress);
  }

  /** 结束任务：恢复空闲状态并提示完成（委托公共函数） */
  private finishTask(message: string): void {
    finishTaskState(message);
  }

  // ── 分类管理（P1-3）──

  private openCategoryPanel(): void {
    this.categoryInput = '';
    this.renameTarget = '';
    this.showCategoryPanel = true;
    this.refreshMeta();
  }

  private closeCategoryPanel(): void {
    this.showCategoryPanel = false;
    this.categoryInput = '';
    this.renameTarget = '';
  }

  /** 提交：重命名模式保存新名；否则新增分类 */
  private submitCategory(): void {
    const name = this.categoryInput.trim();
    if (name === '') {
      promptAction.showToast({ message: '请输入分类名称', duration: 1200 });
      return;
    }
    if (this.renameTarget !== '') {
      modelStore.renameCategory(this.renameTarget, name).then(() => {
        this.renameTarget = '';
        this.categoryInput = '';
        this.bumpAndRefresh();
      }).catch((e: Error) => {
        Logger.error(TAG, '重命名分类失败: %{public}s', JSON.stringify(e));
      });
      return;
    }
    if (this.categories.indexOf(name) >= 0) {
      promptAction.showToast({ message: '分类已存在', duration: 1200 });
      return;
    }
    modelStore.createCategory(name).then(() => {
      this.categoryInput = '';
      this.bumpAndRefresh();
    }).catch((e: Error) => {
      Logger.error(TAG, '新增分类失败: %{public}s', JSON.stringify(e));
    });
  }

  private startRename(name: string): void {
    this.renameTarget = name;
    this.categoryInput = name;
  }

  private cancelRename(): void {
    this.renameTarget = '';
    this.categoryInput = '';
  }

  /** 分类手动排序：上移(-1)/下移(1)，把分类移到相邻目标之前/之后（相邻交换→整体重排） */
  private moveCategory(name: string, dir: number): void {
    const idx = this.categories.indexOf(name);
    const target = idx + dir;
    if (idx < 0 || target < 0 || target >= this.categories.length) {
      return;
    }
    modelStore.swapCategorySort(name, this.categories[target], dir < 0).then(() => {
      this.bumpAndRefresh();
    }).catch((e: Error) => {
      Logger.error(TAG, '分类排序失败: %{public}s', JSON.stringify(e));
    });
  }

  private confirmDeleteCategory(name: string): void {
    this.getUIContext().showAlertDialog({
      title: '删除分类',
      message: `删除分类「${name}」？其下模型将变为未分类（模型文件保留）。`,
      primaryButton: {
        value: '取消',
        action: () => {
        },
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#C12F1C',
        action: () => {
          modelStore.clearCategory(name).then(() => {
            this.bumpAndRefresh();
          }).catch((e: Error) => {
            Logger.error(TAG, '删除分类失败: %{public}s', JSON.stringify(e));
          });
        },
      },
    });
  }

  /** 删除分类下的全部模型（物理删除模型文件 + 数据库记录） */
  private confirmDeleteCategoryModels(name: string): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.getUIContext().showAlertDialog({
      title: '删除分类下模型',
      message: `将删除分类「${name}」下的全部模型文件，且不可恢复，确定继续？`,
      primaryButton: {
        value: '取消',
        action: () => {
        },
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#C12F1C',
        action: () => {
          this.busy = true;
          let ok = 0;
          let fail = 0;
          modelStore.listByCategory(name).then(async (models) => {
            for (const record of models) {
              try {
                await importService.removeModelFiles(ctx, record);
                await modelStore.deleteModel(record.id);
                ok++;
              } catch (e) {
                fail++;
                Logger.error(TAG, '删除分类模型失败: %{public}s/%{public}s, err=%{public}s',
                  record.version, record.entryPath, JSON.stringify(e));
              }
            }
            // 分类下模型清空后删除分类记录本身
            await modelStore.clearCategory(name);
            this.busy = false;
            this.bumpAndRefresh();
            promptAction.showToast({
              message: fail > 0 ? `已删除 ${ok} 个，失败 ${fail} 个` : `已删除 ${ok} 个模型`,
              duration: 1500,
            });
          }).catch((e: Error) => {
            this.busy = false;
            Logger.error(TAG, '删除分类模型异常: %{public}s', JSON.stringify(e));
            promptAction.showToast({ message: '删除失败，请稍后重试', duration: 1500 });
          });
        },
      },
    });
  }

  /** 分类/模型变更后：递增全局版本号（通知模型页/首页刷新）并刷新本页统计 */
  private bumpAndRefresh(): void {
    bumpModelDbVersion();
    this.refreshMeta();
  }

  // ── 备份与恢复 ──

  /** 导出备份：模型+数据打包 zip 保存到用户文档（免权限） */
  private async exportBackupData(): Promise<void> {
    if (this.busy) {
      return;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.busy = true;
    this.setTask('准备导出…', -1);
    this.statusMsg = '准备导出…';
    try {
      const uri = await backupService.exportBackup(ctx, (msg: string) => {
        this.statusMsg = msg;
        this.setTask(msg, -1);
      });
      if (uri === '') {
        this.statusMsg = '';
        this.finishTask('已取消导出');
      } else {
        this.statusMsg = '备份已导出';
        this.finishTask('备份已导出');
      }
    } catch (e) {
      Logger.error(TAG, '导出备份异常: %{public}s', JSON.stringify(e));
      this.statusMsg = '导出失败';
      this.finishTask('导出失败，请重试');
    } finally {
      this.busy = false;
    }
  }

  /** 导入备份：确认覆盖 → 选 zip → 恢复 */
  private confirmImportBackup(): void {
    this.getUIContext().showAlertDialog({
      title: '导入备份',
      message: '将覆盖当前全部模型、缩略图、背景与设置数据。恢复前建议先手动导出一份当前备份。确定继续？',
      primaryButton: {
        value: '取消',
        action: () => {
        },
      },
      secondaryButton: {
        value: '继续',
        fontColor: '#C12F1C',
        action: () => {
          this.pickBackupZip();
        },
      },
    });
  }

  /** 选择备份 zip 并覆盖恢复 */
  private async pickBackupZip(): Promise<void> {
    if (this.busy) {
      return;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const documentPicker = new picker.DocumentViewPicker(ctx);
    let uris: string[] = [];
    try {
      const result = await documentPicker.select({
        maxSelectNumber: 1,
        fileSuffixFilters: ['.zip'],
      });
      uris = result;
    } catch (e) {
      Logger.error(TAG, '选取备份 zip 失败: %{public}s', JSON.stringify(e));
      return;
    }
    if (uris.length === 0) {
      return;
    }
    this.busy = true;
    this.setTask('准备恢复…', -1);
    this.statusMsg = '准备恢复…';
    try {
      const total = await backupService.importBackup(ctx, uris[0], (msg: string) => {
        this.statusMsg = msg;
        this.setTask(msg, -1);
      });
      // 模型/背景/主题均已变化：通知各页刷新
      this.bumpAndRefresh();
      bumpBgVersion();
      this.statusMsg = `恢复完成：共 ${total} 个模型`;
      this.finishTask(`恢复完成：共 ${total} 个模型`);
    } catch (e) {
      Logger.error(TAG, '导入备份异常: %{public}s', JSON.stringify(e));
      this.statusMsg = '恢复失败';
      this.finishTask('恢复失败，请检查备份包');
    } finally {
      this.busy = false;
    }
  }

  /** 清空模型库：删除全部模型文件（含历史残留目录）+ 缩略图 + 数据库记录 */
  private confirmClearLibrary(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.getUIContext().showAlertDialog({
      title: '清空模型库',
      message: '将删除全部模型文件（含历史残留目录）、缩略图和数据库记录，且不可恢复，确定继续？',
      primaryButton: {
        value: '取消',
        action: () => {
        },
      },
      secondaryButton: {
        value: '清空',
        fontColor: '#C12F1C',
        action: () => {
          this.busy = true;
          importService.clearModelsRoot(ctx).then(async () => {
            await thumbnailService.clearAll();
            await modelStore.clearAll();
            this.busy = false;
            this.bumpAndRefresh();
            promptAction.showToast({ message: '模型库已清空', duration: 1500 });
          }).catch((e: Error) => {
            this.busy = false;
            Logger.error(TAG, '清空模型库失败: %{public}s', JSON.stringify(e));
            promptAction.showToast({ message: '清空失败，请稍后重试', duration: 1500 });
          });
        },
      },
    });
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Scroll() {
    Column({ space: 12 }) {
      Text('设置')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.theme().titleColor)
        .width('100%')
        // 与速览页标题同高（速览页标题行 top padding 为 40）
        .padding({ left: 20, top: 40 })

      // ── 导入（U3-3 分组视觉：图标 + 标题 + 分隔线）──
      this.sectionHeader($r('sys.symbol.folder'), '导入')
      Column({ space: 12 }) {
        Row({ space: 10 }) {
          this.actionCard($r('sys.symbol.folder'), this.busy ? '处理中…' : '导入 zip 包', '选择压缩包导入', !this.busy, false, true, () => {
            this.openImportPanel();
          })
          this.actionCard($r('sys.symbol.star'), '内置示例', '一键导入体验', !this.busy, false, false, () => {
            this.importSamples().catch((e: Error) => {
              Logger.error(TAG, '示例导入异常: %{public}s', JSON.stringify(e));
            });
          })
        }
        .width('100%')
        // 任务进度条：导入 / 重新扫描 / 生成缩略图共用（任务结束即隐藏）
        if (this.taskRunning) {
          Column({ space: 6 }) {
            Row() {
              Text(this.taskLabel)
                .fontSize(12)
                .fontColor(this.theme().textSecondary)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (this.taskProgress >= 0) {
                Text(`${this.taskProgress}%`)
                  .fontSize(12)
                  .fontColor(this.theme().accent)
              }
            }
            .width('100%')
            if (this.taskProgress >= 0) {
              // 有明确进度：线性进度条
              Progress({
                value: this.taskProgress,
                total: 100,
                type: ProgressType.Linear,
              })
                .width('100%')
                .color(this.theme().accent)
            } else {
              // 进度未知：环形加载动画（Linear 不支持 LOADING 状态）
              Progress({
                value: 0,
                total: 100,
                type: ProgressType.Ring,
              })
                .style({ status: ProgressStatus.LOADING })
                .width(24)
                .height(24)
                .color(this.theme().accent)
            }
          }
          .width('100%')
        }
        if (this.statusMsg !== '') {
          Text(this.statusMsg)
            .fontSize(12)
            .fontColor(this.theme().accent)
            .width('100%')
        }
      }
      .width('100%')
      .padding(16)
      .backgroundColor(this.theme().card)
      .borderRadius(12)

      // ── 管理 ──
      this.sectionHeader($r('sys.symbol.list_bullet'), '管理')
      Column({ space: 10 }) {
        Row({ space: 10 }) {
          this.actionCard($r('sys.symbol.magnifyingglass'), '重新扫描', '刷新模型目录', !this.busy, false, false, () => {
            this.rescan().catch((e: Error) => {
              Logger.error(TAG, '扫描异常: %{public}s', JSON.stringify(e));
            });
          })
          this.actionCard($r('sys.symbol.ohos_photo'), '补缩略图', '重新生成缺失图', true, false, false, () => {
            const current = AppStorage.get<number>('thumbRegenTick') ?? 0;
            AppStorage.setOrCreate('thumbRegenTick', current + 1);
            promptAction.showToast({ message: '正在重新生成缺失缩略图…', duration: 1200 });
          })
        }
        .width('100%')
        Row({ space: 10 }) {
          this.actionCard($r('sys.symbol.list_bullet'), '分类管理', '分组与删除', true, false, false, () => {
            this.openCategoryPanel();
          })
          this.actionCard($r('sys.symbol.trash'), '清空模型库', '删除全部模型', !this.busy, true, false, () => {
            this.confirmClearLibrary();
          })
        }
        .width('100%')
      }
      .width('100%')
      .padding(16)
      .backgroundColor(this.theme().card)
      .borderRadius(12)

      // ── 备份与恢复 ──
      this.sectionHeader($r('sys.symbol.archivebox'), '备份与恢复')
      Column({ space: 10 }) {
        Row({ space: 10 }) {
          this.actionCard($r('sys.symbol.share'), this.busy ? '处理中…' : '导出备份', '模型+数据打包zip', !this.busy, false, false, () => {
            this.exportBackupData().catch((e: Error) => {
              Logger.error(TAG, '导出备份异常: %{public}s', JSON.stringify(e));
            });
          })
          this.actionCard($r('sys.symbol.folder'), '导入备份', '从zip覆盖恢复', !this.busy, false, false, () => {
            this.confirmImportBackup();
          })
        }
        .width('100%')
        if (this.statusMsg !== '') {
          Text(this.statusMsg)
            .fontSize(12)
            .fontColor(this.theme().accent)
            .width('100%')
        }
      }
      .width('100%')
      .padding(16)
      .backgroundColor(this.theme().card)
      .borderRadius(12)

      // ── 显示（U2-2：速览网格密度）──
      this.sectionHeader($r('sys.symbol.square_grid_2x2'), '显示')
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text('速览网格密度')
            .fontSize(14)
            .fontColor(this.theme().textPrimary)
            .layoutWeight(1)
          ForEach([3, 4, 5], (cols: number) => {
            Text(`${cols} 列`)
              .fontSize(13)
              .fontColor(this.gridCols === cols ? Color.White : this.theme().textPrimary)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(this.gridCols === cols ? this.theme().accent : this.theme().border)
              .borderRadius(10)
              .onClick(() => {
                this.setGridCols(cols);
              })
          }, (cols: number) => `${cols}`)
        }
        .width('100%')
      }
      .width('100%')
      .padding(16)
      .backgroundColor(this.theme().card)
      .borderRadius(12)

      // ── 舞台背景（全局，所有模型共用；模型页舞台最底层渲染）──
      this.sectionHeader($r('sys.symbol.picture'), '舞台背景')
      Column({ space: 12 }) {
        // 当前背景状态行
        Row({ space: 8 }) {
          Text('当前：')
            .fontSize(12)
            .fontColor(this.theme().textSecondary)
          Text(this.stageBg.type === 'image' && this.stageBg.fileName !== ''
            ? this.stageBg.fileName : '主题色（无背景）')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.stageBg.type === 'image' ? this.theme().accent : this.theme().textPrimary)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('全局生效')
            .fontSize(11)
            .fontColor(this.theme().textSecondary)
        }
        .width('100%')

        // 选择列表：主题色块 + 已导入图片（点击应用，选中 ✓，右上角 ✕ 删除）
        Scroll() {
          Row({ space: 10 }) {
            // 主题色（无背景）
            Stack({ alignContent: Alignment.Center }) {
              Column()
                .width(56)
                .height(56)
                .borderRadius(10)
                .backgroundColor(this.theme().stageBg)
                .border({
                  width: this.stageBg.type === 'color' ? 2 : 1,
                  color: this.stageBg.type === 'color' ? this.theme().accentSoft : this.theme().border,
                })
              if (this.stageBg.type === 'color') {
                Text('✓')
                  .fontSize(12)
                  .fontColor(Color.White)
                  .width(20)
                  .height(20)
                  .textAlign(TextAlign.Center)
                  .backgroundColor(this.theme().accent)
                  .borderRadius(10)
              }
            }
            .onClick(() => {
              this.setStageBg({ type: 'color', fileName: '' });
            })

            ForEach(this.bgImages, (f: string) => {
              Stack({ alignContent: Alignment.Center }) {
                Image(`file://${backgroundService.getDir()}/${f}`)
                  .width(56)
                  .height(80)
                  .objectFit(ImageFit.Cover)
                  .borderRadius(10)
                  .border({
                    width: this.stageBg.type === 'image' && this.stageBg.fileName === f ? 2 : 1,
                    color: this.stageBg.type === 'image' && this.stageBg.fileName === f
                      ? this.theme().accentSoft : this.theme().border,
                  })
                if (this.stageBg.type === 'image' && this.stageBg.fileName === f) {
                  Text('✓')
                    .fontSize(12)
                    .fontColor(Color.White)
                    .width(20)
                    .height(20)
                    .textAlign(TextAlign.Center)
                    .backgroundColor(this.theme().accent)
                    .borderRadius(10)
                }
                Text('✕')
                  .fontSize(9)
                  .fontColor(Color.White)
                  .width(18)
                  .height(18)
                  .textAlign(TextAlign.Center)
                  .backgroundColor('#99000000')
                  .borderRadius(9)
                  .position({ x: 36, y: 3 })
                  .onClick(() => {
                    this.deleteBg(f);
                  })
              }
              .onClick(() => {
                this.setStageBg({ type: 'image', fileName: f });
              })
            }, (f: string) => f)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .width('100%')

        // 从相册导入新背景
        Row({ space: 6 }) {
          Text('+')
            .fontSize(16)
            .fontColor(this.theme().accent)
          Text('从相册导入')
            .fontSize(13)
            .fontColor(this.theme().accent)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: 10, bottom: 10 })
        .backgroundColor(`#1A${this.theme().accent.substring(1)}`)
        .borderRadius(10)
        .onClick(() => {
          this.importBg();
        })
      }
      .width('100%')
      .padding(16)
      .backgroundColor(this.theme().card)
      .borderRadius(12)

      this.sectionHeader($r('sys.symbol.heart_fill'), '主题')
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          ForEach(THEMES, (theme: AppTheme) => {
            Column({ space: 4 }) {
              SymbolGlyph(theme.icon)
                .fontSize(24)
                .fontColor([theme.accent])
              Text(theme.name)
                .fontSize(11)
                .fontColor(this.themeId === theme.id ? theme.accent : this.theme().textSecondary)
            }
            .layoutWeight(1)
            .padding({ top: 10, bottom: 8 })
            // 选中：浅色底衬（比边框淡）；未选中：默认边框色浅灰
            .backgroundColor(this.themeId === theme.id ? `#1A${theme.accentSoft.substring(1)}` : this.theme().border)
            .borderRadius(10)
            // 选中描边：2px 浅色强调色（不再用深色 accent，避免外框过深）
            .border({
              width: 2,
              color: this.themeId === theme.id ? theme.accentSoft : 'transparent',
            })
            .onClick(() => {
              themeManager.setTheme(theme.id);
            })
          }, (theme: AppTheme) => theme.id)
        }
        .width('100%')
      }
      .width('100%')
      .padding(16)
      .backgroundColor(this.theme().card)
      .borderRadius(12)

      this.sectionHeader($r('sys.symbol.star'), '关于')
      Column({ space: 8 }) {
        Text(`Cubism 2 模型：${this.c2Count} 个`)
          .fontSize(13)
          .fontColor(this.theme().textSecondary)
          .width('100%')
        Text(`Cubism 3 模型：${this.c3Count} 个`)
          .fontSize(13)
          .fontColor(this.theme().textSecondary)
          .width('100%')
        Text(`模型库合计：${this.c2Count + this.c3Count} 个`)
          .fontSize(13)
          .fontColor(this.theme().textSecondary)
          .width('100%')
        Text(`收藏模型：${this.favoriteCount} 个`)
          .fontSize(13)
          .fontColor(this.theme().textSecondary)
          .width('100%')
        Text(`分类：${this.categories.length} 个`)
          .fontSize(13)
          .fontColor(this.theme().textSecondary)
          .width('100%')
        Text(`磁盘占用：${this.diskUsageLabel}`)
          .fontSize(13)
          .fontColor(this.theme().textSecondary)
          .width('100%')
        Text('渲染引擎：Cubism 3 Core + PIXI（live2dcubismcore.min.js）')
          .fontSize(12)
          .fontColor(this.theme().textSecondary)
          .width('100%')
        Text('渲染引擎：Cubism 2（live2d.js）')
          .fontSize(12)
          .fontColor(this.theme().textSecondary)
          .width('100%')
      }
      .width('100%')
      .padding(16)
      .backgroundColor(this.theme().card)
      .borderRadius(12)

      // ── 更新日志（设置页最底部入口，点击弹窗查看按日期分块的改动记录）──
      Row() {
        SymbolGlyph($r('sys.symbol.clock'))
          .fontSize(18)
          .fontColor([this.theme().accent])
        Text('更新日志')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme().textPrimary)
          .layoutWeight(1)
        Text('查看改动记录')
          .fontSize(12)
          .fontColor(this.theme().textSecondary)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(14)
          .fontColor([this.theme().textSecondary])
      }
      .width('100%')
      .height(52)
      .padding({ left: 16, right: 16 })
      .backgroundColor(this.theme().card)
      .borderRadius(12)
      .onClick(() => {
        this.showChangelog = true;
      })
      .stateStyles({
        pressed: { .opacity(0.7) },
      })
    }
    .width('100%')
    // 底部留白：内容滚动到底时不被悬浮页签栏遮挡
    .padding({ left: 12, right: 12, top: 8, bottom: 110 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.theme().background)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)

      // 分类管理面板：ModalPanelShell 抽壳（遮罩 + 标题 + 内容 @BuilderParam 尾随闭包注入）
      if (this.showCategoryPanel) {
        ModalPanelShell({
          title: '分类管理',
          dismiss: () => {
            this.closeCategoryPanel();
          },
          cardHeight: '72%',
          contentSpacing: 10
        }) {
          this.categoryPanelContent()
        }
      }

      // zip 导入面板：分类输入 + 选取压缩包 + 确认导入（ModalPanelShell 抽壳）
      if (this.showImportPanel) {
        ModalPanelShell({
          title: '导入 zip 模型包',
          dismiss: () => {
            this.closeImportPanel();
          },
          cardHeight: 'auto',
          contentSpacing: 10
        }) {
          this.importPanelContent()
        }
      }

      // 更新日志弹窗：ModalPanelShell 抽壳（按日期分块，块内条目数字序号，内容超长可滚动）
      if (this.showChangelog) {
        ModalPanelShell({
          title: '更新日志',
          dismiss: () => {
            this.showChangelog = false;
          },
          cardHeight: '78%',
          contentSpacing: 8
        }) {
          this.changelogPanelContent()
        }
      }

    }
    .onTouch((event: TouchEvent) => {
      this.onRootTouch(event);
    })
    .translate({ x: this.swipeExitX })
    .opacity(this.swipeExitOpacity)
  }
}

/**
 * 居中模态面板抽壳组件（原 SettingsPage.modalPanel @Builder 重构为独立组件）：
 * 遮罩 + 标题行（标题 + ✕ 关闭）+ 内容区。
 * 内容通过 @BuilderParam 尾随闭包注入（自定义组件一等公民语法，支持 UI 组件语法）。
 * 主题色自行从 AppStorage 读取，不依赖父组件状态。
 */
@Component
struct ModalPanelShell {
  /** 面板内容区（@BuilderParam 尾随闭包注入） */
  @BuilderParam content: () => void;
  /** 面板标题 */
  title: string = '';
  /** 关闭回调（遮罩点击 / ✕ 按钮） */
  dismiss: () => void = () => {};
  /** 卡片高度（'72%' / 'auto' / '78%'） */
  cardHeight: string = 'auto';
  /** 标题行与内容区间距 */
  contentSpacing: number = 8;
  /** 主题 id（AppStorage），变化时驱动面板配色刷新 */
  @StorageProp('themeId') themeId: string = 'pink';

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick(() => {
          this.dismiss();
        })
        .transition(TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.FastOutSlowIn }))

      Column({ space: this.contentSpacing }) {
        Row() {
          Text(this.title)
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(themeManager.getById(this.themeId).titleColor)
          Blank()
          Text('✕')
            .fontSize(18)
            .fontColor(themeManager.getById(this.themeId).textSecondary)
            .onClick(() => {
              this.dismiss();
            })
        }
        .width('100%')

        this.content()
      }
      .width('92%')
      .height(this.cardHeight)
      .padding(16)
      .backgroundColor(themeManager.getById(this.themeId).card)
      .borderRadius(16)
      .transition(
        TransitionEffect.OPACITY
          .combine(TransitionEffect.scale({ x: 0.95, y: 0.95 }))
          .animation({ duration: 200, curve: Curve.FastOutSlowIn })
      )
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }
}
