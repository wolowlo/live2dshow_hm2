/**
 * 全局跨页同步的公共状态工具（AppStorage 封装）。
 * 原则：所有写 AppStorage 的散点逻辑集中在此，页面只调函数，不直接碰 key 字符串，
 * 避免 key 拼写不一致 / 三行重复写入散落各处。
 */
import { promptAction } from '@kit.ArkUI';

const DB_VERSION_KEY = 'modelDbVersion';
const BG_VERSION_KEY = 'bgVersion';
const THUMB_VERSION_KEY = 'thumbVersion';
const TASK_RUNNING_KEY = 'taskRunning';
const TASK_LABEL_KEY = 'taskLabel';
const TASK_PROGRESS_KEY = 'taskProgress';

/** 模型库变更后递增全局版本号，通知模型页/速览页刷新列表 */
export function bumpModelDbVersion(): void {
  const current = AppStorage.get<number>(DB_VERSION_KEY) ?? 0;
  AppStorage.setOrCreate(DB_VERSION_KEY, current + 1);
}

/** 舞台背景变更后递增全局版本号，通知模型页重读背景层 */
export function bumpBgVersion(): void {
  const current = AppStorage.get<number>(BG_VERSION_KEY) ?? 0;
  AppStorage.setOrCreate(BG_VERSION_KEY, current + 1);
}

/** 缩略图重新生成后递增全局版本号，通知模型页卡槽重建刷新图片 */
export function bumpThumbVersion(): void {
  const current = AppStorage.get<number>(THUMB_VERSION_KEY) ?? 0;
  AppStorage.setOrCreate(THUMB_VERSION_KEY, current + 1);
}

/**
 * 启动任务：写入 AppStorage 供设置页进度条显示。
 * @param label 任务描述文案（如「正在生成缩略图 3/10」）
 * @param progress 已知进度 0-100；-1 表示未知（进度条转圈）
 */
export function setTaskState(label: string, progress: number): void {
  AppStorage.setOrCreate(TASK_RUNNING_KEY, true);
  AppStorage.setOrCreate(TASK_LABEL_KEY, label);
  AppStorage.setOrCreate(TASK_PROGRESS_KEY, progress);
}

/** 结束任务：恢复空闲状态（进度条隐藏）；message 非空时弹完成提示 */
export function finishTaskState(message: string = ''): void {
  AppStorage.setOrCreate(TASK_RUNNING_KEY, false);
  AppStorage.setOrCreate(TASK_LABEL_KEY, '');
  AppStorage.setOrCreate(TASK_PROGRESS_KEY, -1);
  if (message !== '') {
    promptAction.showToast({ message, duration: 1500 });
  }
}

/** 重置任务状态为空闲（纯复位，不弹提示；启动初始化用） */
export function resetTaskState(): void {
  AppStorage.setOrCreate(TASK_RUNNING_KEY, false);
  AppStorage.setOrCreate(TASK_LABEL_KEY, '');
  AppStorage.setOrCreate(TASK_PROGRESS_KEY, -1);
}