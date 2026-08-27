import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Logger } from '../common/Logger';
import { ModelRecord } from './ModelRecord';

const TAG = 'ModelStore';
const DB_NAME = 'l2dview.db';
const COL_ACTIONS = 'actions';

/** 模型列表查询条件 */
export interface ModelQuery {
  version?: string;
  category?: string;
  /** 仅查询未分类模型（category 为空串） */
  unCategorizedOnly?: boolean;
  favoriteOnly?: boolean;
  keyword?: string;
}

/** 分类项（含所属版本，模型页菜单按 C2/C3 标注） */
export interface CategoryEntry {
  name: string;
  version: string;
}

/** 备份导出：全部模型记录 + 分类名列表 */
export interface BackupExport {
  models: ModelRecord[];
  categories: string[];
}

/** 模型元数据存储：relationalStore 封装（阶段 2 起承载扫描/分类/收藏等业务） */
export class ModelStore {
  private store: relationalStore.RdbStore | null = null;
  private initReady: Promise<void> | null = null;
  private filesDir: string = '';

  async init(context: common.UIAbilityContext): Promise<void> {
    if (!this.initReady) {
      this.initReady = this.doInit(context);
    }
    await this.initReady;
  }

  /** 初始化主体：建表 + 迁移（幂等，可重入） */
  private async doInit(context: common.UIAbilityContext): Promise<void> {
    this.filesDir = context.filesDir;
    if (!this.store) {
      this.store = await relationalStore.getRdbStore(context, {
        name: DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1,
      });
      await this.store.executeSql(
        'CREATE TABLE IF NOT EXISTS models (' +
          'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
          'version TEXT NOT NULL, ' +
          'group_name TEXT NOT NULL, ' +
          'role_name TEXT NOT NULL, ' +
          'entry_path TEXT NOT NULL, ' +
          'display_name TEXT DEFAULT \'\', ' +
          'category TEXT DEFAULT \'\', ' +
          'favorite INTEGER DEFAULT 0, ' +
          'broken INTEGER DEFAULT 0, ' +
          'created_at INTEGER NOT NULL, ' +
          'canvas_w INTEGER DEFAULT 0, ' +
          'canvas_h INTEGER DEFAULT 0)'
      );
      // 分类表：分类名独立持久化（模型 category 字段引用名称，兼容旧数据）；sort 用于分类手动排序
      await this.store.executeSql(
        'CREATE TABLE IF NOT EXISTS categories (' +
          'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
          'name TEXT NOT NULL UNIQUE, ' +
          'sort INTEGER DEFAULT 0)'
      );
      // 旧库迁移：动作列表列（v1 表无此列）
      await this.ensureColumn(COL_ACTIONS, 'TEXT DEFAULT \'\'');
      await this.ensureColumn('category', 'TEXT DEFAULT \'\'');
      await this.ensureColumn('canvas_w', 'INTEGER DEFAULT 0');
      await this.ensureColumn('canvas_h', 'INTEGER DEFAULT 0');
      // 分类表旧库迁移：新增 sort 列（分类手动排序）
      await this.ensureColumn('sort', 'INTEGER DEFAULT 0', 'categories');
    }
    Logger.info(TAG, '数据库初始化完成');
  }

  /** 确保数据层就绪：查询类调用在 init 完成前等待 */
  private async ensureReady(): Promise<void> {
    if (this.initReady) {
      await this.initReady;
    }
  }

  /** 检测列是否存在，缺失则 ALTER TABLE 补列（幂等迁移）；table 默认 models 表 */
  private async ensureColumn(column: string, definition: string, table: string = 'models'): Promise<void> {
    if (!this.store) {
      return;
    }
    try {
      let exists = false;
      const rs = await this.store.querySql(`PRAGMA table_info(${table})`);
      while (rs.goToNextRow()) {
        if (rs.getString(rs.getColumnIndex('name')) === column) {
          exists = true;
          break;
        }
      }
      rs.close();
      if (!exists) {
        await this.store.executeSql(`ALTER TABLE ${table} ADD COLUMN ${column} ${definition}`);
        Logger.info(TAG, '数据库迁移：%{public}s 表补充列 %{public}s', table, column);
      }
    } catch (e) {
      Logger.warn(TAG, '数据库迁移失败（跳过该列，不影响启动）：%{public}s.%{public}s - %{public}s', table, column, JSON.stringify(e));
    }
  }

  /** 新增模型记录，返回自增 id */
  async addModel(record: ModelRecord): Promise<number> {
    await this.ensureReady();
    if (!this.store) {
      return -1;
    }
    const values: relationalStore.ValuesBucket = {
      'version': record.version,
      'group_name': record.groupName,
      'role_name': record.roleName,
      'entry_path': record.entryPath,
      'display_name': record.displayName,
      'actions': JSON.stringify(record.actions),
      'category': record.category,
      'favorite': record.favorite,
      'broken': record.broken,
      'canvas_w': record.canvasW,
      'canvas_h': record.canvasH,
      'created_at': record.createdAt,
    };
    const rowId = await this.store.insert('models', values);
    return rowId;
  }

  /** 按版本列出全部模型；version 为空时返回全部 */
  async listModels(version?: string): Promise<ModelRecord[]> {
    return this.queryModels({ version });
  }

  /** 按条件查询模型（版本/分类/收藏/坏/关键词） */
  async queryModels(query: ModelQuery): Promise<ModelRecord[]> {
    await this.ensureReady();
    const result: ModelRecord[] = [];
    if (!this.store) {
      return result;
    }
    const predicates = new relationalStore.RdbPredicates('models');
    predicates.orderByDesc('created_at');
    if (query.version !== undefined && query.version !== '' && query.version !== 'all') {
      predicates.equalTo('version', query.version);
    }
    if (query.category !== undefined && query.category !== '') {
      predicates.equalTo('category', query.category);
    }
    if (query.unCategorizedOnly) {
      predicates.equalTo('category', '');
    }
    if (query.favoriteOnly) {
      predicates.equalTo('favorite', 1);
    }
    if (query.keyword !== undefined && query.keyword !== '') {
      predicates.contains('display_name', query.keyword);
      predicates.or();
      predicates.contains('role_name', query.keyword);
    }
    const rs = await this.store.query(predicates);
    while (rs.goToNextRow()) {
      const record = new ModelRecord(
        rs.getString(rs.getColumnIndex('version')),
        rs.getString(rs.getColumnIndex('group_name')),
        rs.getString(rs.getColumnIndex('role_name')),
        rs.getString(rs.getColumnIndex('entry_path')),
        rs.getString(rs.getColumnIndex('display_name')),
        rs.getString(rs.getColumnIndex('category')),
      );
      record.actions = this.parseActions(rs.getString(rs.getColumnIndex(COL_ACTIONS)));
      record.canvasW = rs.getLong(rs.getColumnIndex('canvas_w'));
      record.canvasH = rs.getLong(rs.getColumnIndex('canvas_h'));
      record.id = rs.getLong(rs.getColumnIndex('id'));
      record.favorite = rs.getLong(rs.getColumnIndex('favorite'));
      record.broken = rs.getLong(rs.getColumnIndex('broken'));
      record.createdAt = rs.getLong(rs.getColumnIndex('created_at'));
      result.push(record);
    }
    rs.close();
    return result;
  }

  /** 解析数据库中的动作 JSON 数组（空串/损坏回退空数组） */
  private parseActions(raw: string): string[] {
    if (raw === '') {
      return [];
    }
    try {
      const parsed = JSON.parse(raw) as string[];
      return Array.isArray(parsed) ? parsed : [];
    } catch (e) {
      return [];
    }
  }

  /** 更新收藏状态 */
  async updateFavorite(id: number, favorite: number): Promise<void> {
    await this.ensureReady();
    if (!this.store) {
      return;
    }
    const predicates = new relationalStore.RdbPredicates('models');
    predicates.equalTo('id', id);
    await this.store.update({ 'favorite': favorite }, predicates);
  }

  /** 更新模型分类 */
  async updateCategory(id: number, category: string): Promise<void> {
    await this.ensureReady();
    if (!this.store) {
      return;
    }
    const predicates = new relationalStore.RdbPredicates('models');
    predicates.equalTo('id', id);
    await this.store.update({ 'category': category }, predicates);
  }

  /** 按版本统计模型数量（阶段 1 骨架：用于页面展示） */
  async countByVersion(version: string): Promise<number> {
    await this.ensureReady();
    if (!this.store) {
      return 0;
    }
    const predicates = new relationalStore.RdbPredicates('models');
    predicates.equalTo('version', version);
    const rs = await this.store.query(predicates, ['COUNT(*) AS cnt']);
    let count = 0;
    if (rs.goToNextRow()) {
      count = rs.getLong(rs.getColumnIndex('cnt'));
    }
    rs.close();
    return count;
  }

  /** 列出指定分类下的全部模型（分类删除模型用） */
  async listByCategory(category: string): Promise<ModelRecord[]> {
    return this.queryModels({ category });
  }

  /** 按版本 + 入口路径判断记录是否已存在（扫描去重） */
  async hasRecord(version: string, entryPath: string): Promise<boolean> {
    await this.ensureReady();
    if (!this.store) {
      return false;
    }
    const predicates = new relationalStore.RdbPredicates('models');
    predicates.equalTo('version', version);
    predicates.and();
    predicates.equalTo('entry_path', entryPath);
    const rs = await this.store.query(predicates, ['id']);
    const has = rs.goToNextRow();
    rs.close();
    return has;
  }

  /** 同步模型元数据（显示名/动作列表），保留收藏/坏/分类等用户状态 */
  async updateModelMeta(record: ModelRecord): Promise<void> {
    await this.ensureReady();
    if (!this.store) {
      return;
    }
    const predicates = new relationalStore.RdbPredicates('models');
    predicates.equalTo('version', record.version);
    predicates.and();
    predicates.equalTo('entry_path', record.entryPath);
    await this.store.update({
      'display_name': record.displayName,
      'actions': JSON.stringify(record.actions),
      'canvas_w': record.canvasW,
      'canvas_h': record.canvasH,
    }, predicates);
  }

  /** 删除模型记录（含动作数据清理） */
  async deleteModel(id: number): Promise<void> {
    await this.ensureReady();
    if (!this.store) {
      return;
    }
    const predicates = new relationalStore.RdbPredicates('models');
    predicates.equalTo('id', id);
    await this.store.delete(predicates);
  }

  /** 清空全部模型与分类记录（清空模型库用；文件删除由调用方负责） */
  async clearAll(): Promise<void> {
    await this.ensureReady();
    if (!this.store) {
      return;
    }
    await this.store.executeSql('DELETE FROM models');
    await this.store.executeSql('DELETE FROM categories');
    Logger.info(TAG, '数据库模型/分类记录已清空');
  }

  /** 导出全部模型记录 + 分类名列表（备份用；不含文件） */
  async exportAll(): Promise<BackupExport> {
    await this.ensureReady();
    const models = await this.queryModels({});
    const categories: string[] = [];
    if (this.store) {
      const rs = await this.store.querySql('SELECT name FROM categories ORDER BY id ASC');
      while (rs.goToNextRow()) {
        categories.push(rs.getString(rs.getColumnIndex('name')));
      }
      rs.close();
    }
    const result: BackupExport = { models, categories };
    return result;
  }

  /**
   * 备份恢复：清空两表后重建，返回 (version|entryPath) → 新自增 id 的映射
   * （视角等按 entry_path 记忆的偏好需据此重映射）
   */
  async importAll(models: ModelRecord[], categories: string[]): Promise<Map<string, number>> {
    await this.ensureReady();
    const idMap = new Map<string, number>();
    if (!this.store) {
      return idMap;
    }
    await this.store.beginTransaction();
    try {
      await this.store.executeSql('DELETE FROM models');
      await this.store.executeSql('DELETE FROM categories');
      // 重置自增计数，让新 id 从 1 重新分配（幂等清理，表不存在时忽略）
      try {
        await this.store.executeSql("DELETE FROM sqlite_sequence WHERE name IN ('models','categories')");
      } catch (e) {
        Logger.warn(TAG, '重置自增序列失败(可忽略): %{public}s', JSON.stringify(e));
      }
      for (const record of models) {
        const values: relationalStore.ValuesBucket = {
          'version': record.version,
          'group_name': record.groupName,
          'role_name': record.roleName,
          'entry_path': record.entryPath,
          'display_name': record.displayName,
          'actions': JSON.stringify(record.actions),
          'category': record.category,
          'favorite': record.favorite,
          'broken': record.broken,
          'canvas_w': record.canvasW,
          'canvas_h': record.canvasH,
          'created_at': record.createdAt,
        };
        const rowId = await this.store.insert('models', values);
        idMap.set(`${record.version}|${record.entryPath}`, rowId);
      }
      for (const name of categories) {
        if (name !== '') {
          try {
            await this.store.insert('categories', { 'name': name });
          } catch (e) {
            // 重名分类忽略（UNIQUE 约束兜底）
          }
        }
      }
      await this.store.commit();
      Logger.info(TAG, '备份恢复：重建 %{public}d 个模型、%{public}d 个分类', models.length, categories.length);
    } catch (e) {
      try {
        await this.store.rollBack();
      } catch (rollbackErr) {
        Logger.warn(TAG, '回滚失败: %{public}s', JSON.stringify(rollbackErr));
      }
      Logger.error(TAG, '备份恢复重建失败: %{public}s', JSON.stringify(e));
      throw new Error(JSON.stringify(e));
    }
    return idMap;
  }

  /** 列出全部非空分类名（按手动排序 sort 升序；旧库无 sort 列时退化为按名称排序，绝不空） */
  async listCategories(): Promise<string[]> {
    await this.ensureReady();
    const result: string[] = [];
    if (!this.store) {
      return result;
    }
    try {
      // UNION 结果集列名取第一个 SELECT 的列，ORDER BY 若引用与结果列无关的表达式 SQLite 会报
      // 「1st ORDER BY term does not match any column in the result set」，故外包派生表 t，
      // 排序统一引用 t.name（子查询内的 sort 子查询不受影响，仍可拿到分类真实 sort 值）
      const rs = await this.store.querySql(
        'SELECT t.name FROM (' +
          'SELECT name FROM categories ' +
          'UNION ' +
          "SELECT category AS name FROM models WHERE category != '' " +
          ') t ' +
          'ORDER BY (CASE WHEN t.name IN (SELECT name FROM categories) ' +
          'THEN (SELECT sort FROM categories c WHERE c.name = t.name) ELSE 999999 END), ' +
          't.name COLLATE NOCASE'
      );
      while (rs.goToNextRow()) {
        result.push(rs.getString(rs.getColumnIndex('name')));
      }
      rs.close();
    } catch (e) {
      // 旧库 categories 表缺 sort 列等异常 → 退化为按名称排序（保证分类列表不空）
      Logger.warn(TAG, '分类排序查询异常，退化为按名称排序：%{public}s', JSON.stringify(e));
      try {
        const rs = await this.store.querySql(
          "SELECT name FROM categories " +
            "UNION SELECT category AS name FROM models WHERE category != '' " +
            'ORDER BY name COLLATE NOCASE'
        );
        while (rs.goToNextRow()) {
          result.push(rs.getString(rs.getColumnIndex('name')));
        }
        rs.close();
      } catch (e2) {
        // 极老库连 models.category 列都没有（迁移失败时）→ 只取分类表，保证列表非空
        Logger.warn(TAG, '分类退化查询再失败，仅取分类表：%{public}s', JSON.stringify(e2));
        try {
          const rs = await this.store.querySql('SELECT name FROM categories ORDER BY name COLLATE NOCASE');
          while (rs.goToNextRow()) {
            result.push(rs.getString(rs.getColumnIndex('name')));
          }
          rs.close();
        } catch (e3) {
          Logger.error(TAG, '分类列表查询最终失败: %{public}s', JSON.stringify(e3));
        }
      }
    }
    return result;
  }

  /** 列出带版本维度的分类（去重，按手动排序；供模型页菜单标注 C2/C3） */
  async listCategoryEntries(): Promise<CategoryEntry[]> {
    await this.ensureReady();
    const result: CategoryEntry[] = [];
    if (!this.store) {
      return result;
    }
    try {
      // 与 listCategories 同理：ORDER BY 引用 sort_key 表达式时 SQLite 会报
      // 「1st ORDER BY term does not match any column in the result set」，
      // 外包派生表 t，排序引用 t.name（sort 取数逻辑不变）
      const rs = await this.store.querySql(
        'SELECT t.name, t.version FROM (' +
          "SELECT category AS name, version FROM models " +
          "WHERE category != '' " +
          'GROUP BY category, version ' +
          ') t ' +
          'ORDER BY (CASE WHEN t.name IN (SELECT name FROM categories) ' +
          'THEN (SELECT sort FROM categories c WHERE c.name = t.name) ELSE 999999 END), ' +
          't.name COLLATE NOCASE, t.version'
      );
      while (rs.goToNextRow()) {
        result.push({
          name: rs.getString(rs.getColumnIndex('name')),
          version: rs.getString(rs.getColumnIndex('version')),
        });
      }
      rs.close();
    } catch (e) {
      // 旧库缺 sort 列等异常 → 退化为基础查询（按名称、版本排序）
      Logger.warn(TAG, '分类条目排序查询异常，退化基础查询：%{public}s', JSON.stringify(e));
      try {
        const rs = await this.store.querySql(
          "SELECT category AS name, version FROM models " +
            "WHERE category != '' " +
            "GROUP BY category, version " +
            "ORDER BY name COLLATE NOCASE, version"
        );
        while (rs.goToNextRow()) {
          result.push({
            name: rs.getString(rs.getColumnIndex('name')),
            version: rs.getString(rs.getColumnIndex('version')),
          });
        }
        rs.close();
      } catch (e2) {
        // 极老库连 models.category 列都没有 → 返回空（分类不涉及）
        Logger.warn(TAG, '分类条目退化查询再失败，返回空：%{public}s', JSON.stringify(e2));
      }
    }
    return result;
  }

  /** 新增分类（已存在则忽略；sort 取当前最大 +1，追加到末尾） */
  async createCategory(name: string): Promise<void> {
    await this.ensureReady();
    if (!this.store || name === '') {
      return;
    }
    let nextSort = 0;
    try {
      const rs = await this.store.querySql('SELECT COALESCE(MAX(sort), 0) AS m FROM categories');
      if (rs.goToNextRow()) {
        nextSort = rs.getLong(rs.getColumnIndex('m')) + 1;
      }
      rs.close();
    } catch (e) {
      // 旧库缺 sort 列：无法分配 sort，退回只写 name（排序功能后续列补齐后生效）
      Logger.warn(TAG, '分配分类 sort 失败（缺列），仅写 name：%{public}s', JSON.stringify(e));
      const values: relationalStore.ValuesBucket = { 'name': name };
      await this.store.insert('categories', values);
      return;
    }
    const values: relationalStore.ValuesBucket = { 'name': name, 'sort': nextSort };
    await this.store.insert('categories', values);
  }

  /**
   * 分类手动排序：把 fromName 移到 toName 之前（-1）或之后（1）。
   * 实现为「以当前 listCategories 顺序为基准，按目标位置重排后整体刷新 sort」
   * ——而不是简单交换两个 sort 值，可修正重复/空洞/999999 等历史脏数据，
   * 也保证「不在分类表中的模型侧分类」不参与交换（它们在当前列表靠后，移动即重编号）。
   */
  async swapCategorySort(fromName: string, toName: string, before: boolean): Promise<void> {
    await this.ensureReady();
    if (!this.store || fromName === '' || toName === '' || fromName === toName) {
      return;
    }
    // 以当前列表顺序为基准（含分类表 + 模型侧分类，与 listCategories 同序）
    const all = await this.listCategories();
    const fromIdx = all.indexOf(fromName);
    const toIdx = all.indexOf(toName);
    if (fromIdx < 0 || toIdx < 0) {
      return;
    }
    // 从原列表剔除 fromName，再按 before 语义插入到 toName 相对位置
    const rest: string[] = [];
    for (const n of all) {
      if (n !== fromName) {
        rest.push(n);
      }
    }
    // rest 中 toName 的实际位置：若 fromName 原本在 toName 之前，删除后 toName 索引前移一位
    const toPosInRest = toIdx - (fromIdx < toIdx ? 1 : 0);
    const insertAt = toPosInRest + (before ? 0 : 1);
    const reordered: string[] = [];
    for (let i = 0; i < rest.length; i++) {
      if (i === insertAt) {
        reordered.push(fromName);
      }
      reordered.push(rest[i]);
    }
    if (reordered.length < rest.length + 1) {
      reordered.push(fromName);
    }
    // 整体重编号：顺序即新 sort（1..n），分类表逐条更新；不在分类表中的模型侧分类跳过（其位置已体现在列表里）
    try {
      await this.store.beginTransaction();
      for (let i = 0; i < reordered.length; i++) {
        const name = reordered[i];
        const predicates = new relationalStore.RdbPredicates('categories');
        predicates.equalTo('name', name);
        const count = await this.store.update({ 'sort': i + 1 }, predicates);
        if (count === 0) {
          // 模型侧分类不在分类表 → 补入分类表并赋 sort（保证后续重复操作稳定）
          await this.store.insert('categories', { 'name': name, 'sort': i + 1 });
        }
      }
      await this.store.commit();
      Logger.info(TAG, '分类顺序重排完成: %{public}s', JSON.stringify(reordered));
    } catch (e) {
      try {
        await this.store.rollBack();
      } catch (rollbackErr) {
        Logger.warn(TAG, '重排回滚失败: %{public}s', JSON.stringify(rollbackErr));
      }
      Logger.error(TAG, '分类顺序重排失败: %{public}s', JSON.stringify(e));
      throw new Error(JSON.stringify(e));
    }
  }

  /** 分类重命名（级联更新该分类下全部模型） */
  async renameCategory(oldName: string, newName: string): Promise<void> {
    await this.ensureReady();
    if (!this.store || oldName === '' || newName === '') {
      return;
    }
    const catPredicates = new relationalStore.RdbPredicates('categories');
    catPredicates.equalTo('name', oldName);
    await this.store.update({ 'name': newName }, catPredicates);
    const predicates = new relationalStore.RdbPredicates('models');
    predicates.equalTo('category', oldName);
    await this.store.update({ 'category': newName }, predicates);
  }

  /** 删除分类：删除分类记录，并将该分类下模型的分类清空（不物理删除模型，安全降级） */
  async clearCategory(name: string): Promise<void> {
    await this.ensureReady();
    if (!this.store || name === '') {
      return;
    }
    const catPredicates = new relationalStore.RdbPredicates('categories');
    catPredicates.equalTo('name', name);
    await this.store.delete(catPredicates);
    const predicates = new relationalStore.RdbPredicates('models');
    predicates.equalTo('category', name);
    await this.store.update({ 'category': '' }, predicates);
  }

}

/** 模块级单例：全应用共享一个数据层实例 */
export const modelStore: ModelStore = new ModelStore();
