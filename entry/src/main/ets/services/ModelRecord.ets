/** 模型元数据记录（对应 relationalStore 的 models 表） */
export class ModelRecord {
  id: number = 0;
  /** cubism2 | cubism3 */
  version: string = '';
  /** 分组名（Cubism 3 为 group/role 的第一段；Cubism 2 为 model 下的子目录） */
  groupName: string = '';
  /** 角色名（模型目录名） */
  roleName: string = '';
  /** 入口文件相对路径，如 zhala_2/zhala_2 或 model/SacredSwordprincesses/char_cg_live2d_025/model.json */
  entryPath: string = '';
  /** 展示名（优先取模型内声明的名称，缺省用目录名） */
  displayName: string = '';
  /** 可用动作名列表（C2：motions/*.mtn 文件名；C3：model3.json 声明的动作名） */
  actions: string[] = [];
  /** Cubism 2 .moc 画布尺寸（渲染页按此比例 contain 适配，缺省 0） */
  canvasW: number = 0;
  canvasH: number = 0;
  category: string = '';
  favorite: number = 0;
  broken: number = 0;
  createdAt: number = 0;

  constructor(version: string, groupName: string, roleName: string, entryPath: string,
    displayName: string, category: string = '', actions: string[] = []) {
    this.version = version;
    this.groupName = groupName;
    this.roleName = roleName;
    this.entryPath = entryPath;
    this.displayName = displayName;
    this.category = category;
    this.actions = actions;
    this.createdAt = Date.now();
  }
}
