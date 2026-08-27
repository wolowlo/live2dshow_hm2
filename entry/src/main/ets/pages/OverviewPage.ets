import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { modelStore } from '../services/ModelStore';
import { thumbnailService } from '../services/ThumbnailService';
import { themeManager, AppTheme } from '../services/ThemeManager';
import { ModelRecord } from '../services/ModelRecord';
import { importService } from '../services/ImportService';
import { Logger } from '../common/Logger';

const TAG = 'OverviewPage';

/** 分类分组：分类名 + 该分类下的模型列表 */
interface CategoryGroup {
  name: string;
  models: ModelRecord[];
}

/**
 * 模型速览页：按分类分组展示缩略图网格（每行 4 个）。
 * 点击缩略图跳转到模型页并定位到对应模型（卡槽跟随滚动）。
 */
@Component
export struct OverviewPage {
  @State groups: CategoryGroup[] = [];
  /** 用户显式折叠的分类名（区别于默认策略，点击标题后记录） */
  @State userCollapsedGroups: string[] = [];
  /** 用户显式展开的分类名（覆盖"超 20 个默认折叠"策略） */
  @State userExpandedGroups: string[] = [];
  /** 强制刷新计数：参与 ForEach key，删除/移动后强制重建列表 */
  @State refreshTick: number = 0;
  /** 全部分类名（含空分类，来自分类表），供移动分类菜单使用 */
  @State allCategories: string[] = [];
  /** 是否处于多选模式（长按缩略图进入） */
  @State multiSelect: boolean = false;
  /** 已勾选的模型 entryPath 列表 */
  @State selectedKeys: string[] = [];
  /** 缩略图生成完成计数：参与 ForEach key，生成后强制重建卡片重新加载图片 */
  @StorageProp('thumbVersion') thumbVersion: number = 0;
  /** 网格密度：3/4/5 列（设置页选择，AppStorage 持久化） */
  @StorageProp('overviewGridCols') gridCols: number = 4;
  /** 切页退场动画：位移 X / 透明度 */
  @State swipeExitX: number = 0;
  @State swipeExitOpacity: number = 1;
  /** 长按刚触发：抑制随后一次 onClick（避免抬起时把勾选取消） */
  private suppressClick: boolean = false;
  /** 页面左右滑动的起点（用于切换相邻页面） */
  private swipeStartX: number = 0;
  private swipeStartY: number = 0;
  @StorageProp('themeId') themeId: string = 'pink';
  @StorageProp('modelDbVersion') @Watch('onDbVersionChange') modelDbVersion: number = 0;
  /** 多选状态同步到 AppStorage：Index 拦截系统返回键用 */
  @StorageProp('overviewMultiSelect') @Watch('onMultiSelectState') multiSelectState: boolean = false;

  aboutToAppear(): void {
    this.loadGroups();
  }

  aboutToDisappear(): void {
    // 离开页面时恢复底部导航栏
    AppStorage.setOrCreate('hideTabBar', false);
  }

  private onDbVersionChange(): void {
    this.loadGroups();
  }

  /** AppStorage 多选状态变化：外部置 true 时进入多选；Index 返回键置 false 时同步退出 */
  private onMultiSelectState(): void {
    if (this.multiSelectState && !this.multiSelect) {
      this.multiSelect = true;
      AppStorage.setOrCreate('hideTabBar', true);
      this.suppressClick = false;
    } else if (!this.multiSelectState && this.multiSelect) {
      this.exitMultiSelect();
    }
  }

  private theme(): AppTheme {
    return themeManager.getById(this.themeId);
  }

  /** 网格卡片宽度百分比：3/4/5 列 → (100 - 2*列数)/列数（卡片左右各 1% 间距） */
  private gridCardWidth(): string {
    const cols = this.gridCols === 3 || this.gridCols === 5 ? this.gridCols : 4;
    const width = (100 - 2 * cols) / cols;
    return `${Math.round(width * 100) / 100}%`;
  }

  /** 网格卡片高度：3 列卡片更宽按比例加高，5 列更窄相应减矮，保持缩略图观感一致 */
  private gridCardHeight(): number {
    if (this.gridCols === 3) {
      return 110;
    }
    if (this.gridCols === 5) {
      return 60;
    }
    return 76;
  }

  /** 页面左右滑：右滑回模型页，左滑进设置页（多选时禁用） */
  private onRootTouch(event: TouchEvent): void {
    if (this.multiSelect) {
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
      // 仅当水平是主方向时才切页（纵向滚动时手稍偏不会误触发）
      if (Math.abs(dx) > 60 && Math.abs(dx) > Math.abs(dy) * 1.2) {
        // 先播退场动画再切页，避免瞬间跳变
        this.switchPageWithAnim(dx > 0 ? 0 : 2, dx > 0 ? 1 : -1);
      }
    }
  }

  /** 页面滑出动画结束后切换（direction：右滑=1 页面向右退场，左滑=-1 页面向左退场） */
  private switchPageWithAnim(target: number, direction: number): void {
    this.getUIContext().animateTo({ duration: 280, curve: Curve.EaseInOut }, () => {
      this.swipeExitX = direction * 50;
      this.swipeExitOpacity = 0;
    });
    setTimeout(() => {
      AppStorage.setOrCreate('currentTabIndex', target);
      this.swipeExitX = 0;
      this.swipeExitOpacity = 1;
    }, 300);
  }

  /** 加载全部模型并按分类分组（未分类放最后） */
  private async loadGroups(): Promise<void> {
    try {
      this.allCategories = await modelStore.listCategories();
      const models = await modelStore.queryModels({});
      // 分组顺序 = listCategories 返回的手动排序（设置页分类管理上移/下移调整）；
      // 分类不在 listCategories 里的按模型中首次出现顺序追加
      const names: string[] = [];
      const byCategory: Record<string, ModelRecord[]> = {};
      const unCategorized: ModelRecord[] = [];
      for (const m of models) {
        if (m.category === '') {
          unCategorized.push(m);
        } else {
          if (!byCategory[m.category]) {
            byCategory[m.category] = [];
            names.push(m.category);
          }
          byCategory[m.category].push(m);
        }
      }
      const orderedNames: string[] = [];
      for (const n of this.allCategories) {
        if (byCategory[n]) {
          orderedNames.push(n);
        }
      }
      for (const n of names) {
        if (orderedNames.indexOf(n) < 0) {
          orderedNames.push(n);
        }
      }
      const groups: CategoryGroup[] = [];
      for (const name of orderedNames) {
        groups.push({ name, models: byCategory[name] });
      }
      if (unCategorized.length > 0) {
        groups.push({ name: '未分类', models: unCategorized });
      }
      this.groups = groups;
      // 清理已失效的折叠/展开记录（分类被删除/清空后不残留）
      const validNames: string[] = [];
      for (const g of groups) {
        validNames.push(g.name);
      }
      this.userCollapsedGroups = this.userCollapsedGroups.filter((n: string) => validNames.indexOf(n) >= 0);
      this.userExpandedGroups = this.userExpandedGroups.filter((n: string) => validNames.indexOf(n) >= 0);
    } catch (e) {
      Logger.error(TAG, '加载速览失败: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 分类折叠状态：
   * - 用户显式操作过（折叠/展开列表命中）→ 以用户选择为准
   * - 未操作过 → 默认策略：模型数 > 20 折叠，<= 20 展开
   */
  private isGroupCollapsed(name: string, count: number): boolean {
    if (this.userCollapsedGroups.indexOf(name) >= 0) {
      return true;
    }
    if (this.userExpandedGroups.indexOf(name) >= 0) {
      return false;
    }
    return count > 20;
  }

  /** 点击分类标题：切换折叠状态，并记录用户显式选择（覆盖默认策略） */
  private toggleGroup(name: string, count: number): void {
    const collapsed = this.isGroupCollapsed(name, count);
    const removeName = (list: string[]): void => {
      const idx = list.indexOf(name);
      if (idx >= 0) {
        list.splice(idx, 1);
      }
    };
    if (collapsed) {
      // 当前折叠 → 展开：清掉显式折叠记录；若默认策略是折叠（>20），记录显式展开
      removeName(this.userCollapsedGroups);
      if (count > 20) {
        this.userExpandedGroups.push(name);
      }
    } else {
      // 当前展开 → 折叠：清掉显式展开记录；若默认策略是展开（<=20），记录显式折叠
      removeName(this.userExpandedGroups);
      if (count <= 20) {
        this.userCollapsedGroups.push(name);
      }
    }
  }

  /** 点击缩略图：通知模型页选中该模型并切换到模型页 */
  private openModel(record: ModelRecord): void {
    AppStorage.setOrCreate('overviewSelectPath', record.entryPath);
    AppStorage.setOrCreate('currentTabIndex', 0);
  }

  // ── 多选 ──

  /** 长按缩略图：进入多选模式并勾选该模型 */
  private longPressModel(record: ModelRecord): void {
    this.multiSelect = true;
    AppStorage.setOrCreate('overviewMultiSelect', true);
    AppStorage.setOrCreate('hideTabBar', true);
    this.toggleSelect(record.entryPath);
    this.suppressClick = true;
  }

  /** 点击缩略图：多选模式切换勾选，普通模式跳转模型页 */
  private tapModel(record: ModelRecord): void {
    if (this.suppressClick) {
      this.suppressClick = false;
      return;
    }
    if (this.multiSelect) {
      this.toggleSelect(record.entryPath);
    } else {
      this.openModel(record);
    }
  }

  private toggleSelect(key: string): void {
    const idx = this.selectedKeys.indexOf(key);
    if (idx >= 0) {
      this.selectedKeys.splice(idx, 1);
    } else {
      this.selectedKeys.push(key);
    }
  }

  private isSelected(key: string): boolean {
    return this.selectedKeys.indexOf(key) >= 0;
  }

  private exitMultiSelect(): void {
    this.multiSelect = false;
    this.selectedKeys = [];
    AppStorage.setOrCreate('overviewMultiSelect', false);
    AppStorage.setOrCreate('hideTabBar', false);
  }

  /** 收藏按钮文案：选中模型全部已收藏则显示“取消收藏”，否则“收藏” */
  private favoriteLabel(): string {
    if (this.selectedKeys.length === 0) {
      return '收藏';
    }
    let allFav = true;
    let found = 0;
    for (const g of this.groups) {
      for (const m of g.models) {
        if (this.selectedKeys.indexOf(m.entryPath) >= 0) {
          found++;
          if (m.favorite !== 1) {
            allFav = false;
          }
        }
      }
    }
    return found > 0 && allFav ? '取消收藏' : '收藏';
  }

  /** 批量收藏/取消收藏选中的模型 */
  private async toggleFavoriteSelected(): Promise<void> {
    if (this.selectedKeys.length === 0) {
      return;
    }
    const selected: ModelRecord[] = [];
    for (const g of this.groups) {
      for (const m of g.models) {
        if (this.selectedKeys.indexOf(m.entryPath) >= 0) {
          selected.push(m);
        }
      }
    }
    if (selected.length === 0) {
      return;
    }
    const allFav = selected.every((m: ModelRecord) => m.favorite === 1);
    const next = allFav ? 0 : 1;
    try {
      for (const m of selected) {
        await modelStore.updateFavorite(m.id, next);
      }
      await this.loadGroups();
      this.refreshTick++;
      this.exitMultiSelect();
      promptAction.showToast({ message: next === 1 ? '已收藏' : '已取消收藏', duration: 1200 });
    } catch (e) {
      Logger.error(TAG, '批量收藏失败: %{public}s', JSON.stringify(e));
      promptAction.showToast({ message: '收藏操作失败，请稍后重试', duration: 1200 });
    }
  }

  /** 移动分类菜单：从已有分类中选择（含“未分类”清空分类） */
  private categoryMenuOptions(): MenuElement[] {
    const options: MenuElement[] = [];
    for (const name of this.allCategories) {
      options.push({
        value: name,
        action: () => {
          this.applyCategory(name);
        },
      });
    }
    options.push({
      value: '未分类',
      action: () => {
        this.applyCategory('');
      },
    });
    return options;
  }

  /** 把勾选模型批量移动到指定分类（'' = 未分类） */
  private async applyCategory(category: string): Promise<void> {
    if (this.selectedKeys.length === 0) {
      return;
    }
    try {
      const models = await modelStore.listModels();
      let updated = 0;
      for (const m of models) {
        if (this.selectedKeys.indexOf(m.entryPath) >= 0) {
          await modelStore.updateCategory(m.id, category);
          updated++;
        }
      }
      Logger.info(TAG, '批量移动分类: 目标=%{public}s, 更新 %{public}d 个', category, updated);
      if (updated === 0) {
        promptAction.showToast({ message: '未找到匹配的模型，分类未变更', duration: 1200 });
        return;
      }
      // 立即本地刷新（分组 + 全量分类），并强制重建列表
      await this.loadGroups();
      this.refreshTick++;
      this.bumpAndExit(`已移动 ${updated} 个模型到「${category === '' ? '未分类' : category}」`);
    } catch (e) {
      Logger.error(TAG, '批量移动分类失败: %{public}s', JSON.stringify(e));
      promptAction.showToast({ message: '移动分类失败，请稍后重试', duration: 1200 });
    }
  }

  /** 删除勾选模型：确认后物理删除文件 + 记录 + 缩略图 */
  private confirmDeleteSelected(): void {
    if (this.selectedKeys.length === 0) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '删除模型',
      message: `将删除选中的 ${this.selectedKeys.length} 个模型，且不可恢复，确定继续？`,
      primaryButton: {
        value: '取消',
        action: () => {
        },
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#C12F1C',
        action: () => {
          this.deleteSelected();
        },
      },
    });
  }

  private async deleteSelected(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const models = await modelStore.listModels();
      let removed = 0;
      for (const m of models) {
        if (this.selectedKeys.indexOf(m.entryPath) >= 0) {
          await importService.removeModelFiles(ctx, m);
          await modelStore.deleteModel(m.id);
          removed++;
        }
      }
      // 立即从本地分组中移除被删模型，界面马上更新（不依赖重新查库）
      const removedSet: Set<string> = new Set(this.selectedKeys);
      const nextGroups: CategoryGroup[] = [];
      for (const g of this.groups) {
        const keep = g.models.filter((m: ModelRecord) => !removedSet.has(m.entryPath));
        if (keep.length > 0) {
          nextGroups.push({ name: g.name, models: keep });
        }
      }
      this.groups = nextGroups;
      this.refreshTick++;
      Logger.info(TAG, '删除后本地分组刷新: %{public}d -> %{public}d 组',
        removed, nextGroups.length);
      // 重新从数据库加载，确保与库一致（await 避免与本地过滤竞态）
      await this.loadGroups();
      this.refreshTick++;
      this.bumpAndExit(removed > 0 ? `已删除 ${removed} 个模型` : '未找到可删除的模型');
    } catch (e) {
      Logger.error(TAG, '批量删除模型失败: %{public}s', JSON.stringify(e));
      promptAction.showToast({ message: '删除失败，请稍后重试', duration: 1200 });
    }
  }

  /** 操作完成：递增模型库版本触发全局刷新，退出多选并提示 */
  private bumpAndExit(message: string): void {
    const current = AppStorage.get<number>('modelDbVersion') ?? 0;
    AppStorage.setOrCreate('modelDbVersion', current + 1);
    this.exitMultiSelect();
    promptAction.showToast({ message, duration: 1200 });
  }

  build() {
    Column() {
      // 标题行：左侧标题，右侧多选/完成按钮
      Row() {
        Text('模型速览')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme().titleColor)
        Blank()
        Text(this.multiSelect ? '完成' : '多选')
          .fontSize(14)
          .fontColor(this.multiSelect ? Color.White : this.theme().textSecondary)
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .backgroundColor(this.multiSelect ? this.theme().accent : this.theme().border)
          .borderRadius(8)
          .onClick(() => {
            if (this.multiSelect) {
              this.exitMultiSelect();
            } else {
              this.multiSelect = true;
              AppStorage.setOrCreate('overviewMultiSelect', true);
              AppStorage.setOrCreate('hideTabBar', true);
            }
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 40 })

      Scroll() {
        Column({ space: 18 }) {
          if (this.groups.length === 0) {
            Column() {
              Text('暂无模型，请先导入或恢复备份')
                .fontSize(14)
                .fontColor(this.theme().textSecondary)
                .textAlign(TextAlign.Center)
            }
            .width('100%')
            .padding({ top: 60, bottom: 60 })
          }
          ForEach(this.groups, (group: CategoryGroup) => {
            Column({ space: 8 }) {
              // 分类标题行：名称 + 数量统计 + 折叠箭头，点击折叠/展开该分类
              Row() {
                Text(group.name)
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.theme().titleColor)
                Text(`${group.models.length}`)
                  .fontSize(12)
                  .fontColor(this.theme().textSecondary)
                  .backgroundColor(this.theme().border)
                  .borderRadius(9)
                  .padding({ left: 7, right: 7, top: 1, bottom: 1 })
                  .margin({ left: 8 })
                Blank()
                Text(this.isGroupCollapsed(group.name, group.models.length) ? '▸' : '▾')
                  .fontSize(13)
                  .fontColor(this.theme().textSecondary)
              }
              .width('100%')
              .padding({ top: 4, bottom: 4 })
              .onClick(() => {
                this.toggleGroup(group.name, group.models.length);
              })
              // 缩略图网格：每行 3/4/5 列（密度可调），折叠时不渲染
              if (!this.isGroupCollapsed(group.name, group.models.length)) {
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(group.models, (item: ModelRecord) => {
                    Stack({ alignContent: Alignment.TopEnd }) {
                      Image(`file://${thumbnailService.thumbPath(item.entryPath)}`)
                        .width('100%')
                        .height(this.gridCardHeight())
                        .objectFit(ImageFit.Cover)
                        .backgroundColor('#F1F3F5')
                        .borderRadius(8)
                      // 多选勾选角标
                      if (this.multiSelect) {
                        Text(this.isSelected(item.entryPath) ? '✓' : '')
                          .fontSize(14)
                          .fontColor(Color.White)
                          .width(22)
                          .height(22)
                          .textAlign(TextAlign.Center)
                          .backgroundColor(this.isSelected(item.entryPath)
                            ? this.theme().accent : '#66000000')
                          .borderRadius(11)
                          .border({
                            width: 1,
                            color: Color.White,
                          })
                          .margin(4)
                      }
                    }
                    .width(this.gridCardWidth())
                    .height(this.gridCardHeight())
                    .borderRadius(8)
                    .clip(true)
                    .opacity(this.multiSelect && !this.isSelected(item.entryPath) ? 0.55 : 1)
                    .margin({ left: '1%', right: '1%', bottom: 10 })
                    .gesture(
                      LongPressGesture({ repeat: false })
                        .onAction(() => {
                          this.longPressModel(item);
                        })
                    )
                    .onClick(() => {
                      this.tapModel(item);
                    })
                  }, (item: ModelRecord) => `${item.entryPath}|${this.thumbVersion}`)
                }
                .width('100%')
              }
            }
            .width('100%')
          }, (group: CategoryGroup) => `${group.name}|${this.refreshTick}`)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 110 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      // 内容不满一屏时从左上角开始排（Scroll 默认 align 是 Center，会垂直居中）
      .align(Alignment.TopStart)

      // 多选操作栏：收藏 / 移动分类 / 删除（退出多选用右上角「完成」或返回键）
      if (this.multiSelect) {
        Row({ space: 8 }) {
          Text(`已选 ${this.selectedKeys.length} 个`)
            .fontSize(11)
            .fontColor(this.theme().textSecondary)
          Blank()
          Text(this.favoriteLabel())
            .fontSize(14)
            .fontColor(Color.White)
            .padding({ left: 10, right: 10, top: 8, bottom: 8 })
            .backgroundColor(this.theme().accent)
            .borderRadius(10)
            .onClick(() => {
              this.toggleFavoriteSelected().catch((e: Error) => {
                Logger.error(TAG, '收藏切换异常: %{public}s', JSON.stringify(e));
              });
            })
          Text('移动分类')
            .fontSize(14)
            .fontColor(Color.White)
            .padding({ left: 10, right: 10, top: 8, bottom: 8 })
            .backgroundColor(this.theme().accent)
            .borderRadius(10)
            .bindMenu(this.categoryMenuOptions())
          Text('删除')
            .fontSize(14)
            .fontColor(Color.White)
            .padding({ left: 10, right: 10, top: 8, bottom: 8 })
            .backgroundColor('#C12F1C')
            .borderRadius(10)
            .onClick(() => {
              this.confirmDeleteSelected();
            })
        }
        .width('100%')
        // 往上抬：底部留更大间距，操作栏离开屏幕底部
        .padding({ left: 16, right: 16, top: 10, bottom: 40 })
        .backgroundColor(this.theme().card)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme().background)
    .translate({ x: this.swipeExitX })
    .opacity(this.swipeExitOpacity)
    .onTouch((event: TouchEvent) => {
      this.onRootTouch(event);
    })
  }
}
