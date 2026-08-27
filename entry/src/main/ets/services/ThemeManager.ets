import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { Logger } from '../common/Logger';

const TAG = 'Theme';
const THEME_KEY = 'themeId';
const PREF_NAME = 'app_settings';

/** 一套主题的配色 */
export interface AppTheme {
  id: string;
  name: string;
  icon: Resource;
  background: string;
  card: string;
  textPrimary: string;
  textSecondary: string;
  accent: string;
  /** 选中描边/光晕用的浅色强调色：比 accent 淡，避免实色描边过深过丑（不参与文字对比度） */
  accentSoft: string;
  stageBg: string;
  border: string;
  /** 标题色：主题色的加深版（页面大标题用） */
  titleColor: string;
  /** 是否深色主题（用于状态栏/导航条图标颜色） */
  isDark: boolean;
}

/** 三套主题（与网页版一致的语义：粉紫 / 淡黄 / 靛青） */
export const THEMES: AppTheme[] = [
  {
    id: 'pink',
    name: '可爱粉紫',
    icon: $r('sys.symbol.heart_fill'),
    background: '#FFF5F8',
    card: '#FFFFFF',
    textPrimary: '#3A2E3E',
    textSecondary: '#73617A',
    accent: '#99326F',
    accentSoft: '#E59FC4',
    stageBg: '#FDF1F6',
    border: '#F3E2EC',
    titleColor: '#C14E92',
    isDark: false,
  },
  {
    id: 'honey',
    name: '温馨淡黄',
    icon: $r('sys.symbol.sun_max_fill'),
    background: '#FFF9EC',
    card: '#FFFFFF',
    textPrimary: '#4A3B20',
    textSecondary: '#736541',
    accent: '#8A5C00',
    accentSoft: '#D9A23B',
    stageBg: '#FDF6E3',
    border: '#F0E5C8',
    titleColor: '#B9850A',
    isDark: false,
  },
  {
    id: 'teal',
    name: '活泼靛青',
    icon: $r('sys.symbol.drop_fill'),
    background: '#F0F8FA',
    card: '#FFFFFF',
    textPrimary: '#23343C',
    textSecondary: '#566C78',
    accent: '#176663',
    accentSoft: '#7FC8C4',
    stageBg: '#E9F6F7',
    border: '#D8ECEF',
    titleColor: '#0A918B',
    isDark: false,
  },
];

/** 主题管理：AppStorage 驱动 UI 刷新，preferences 持久化 */
export class ThemeManager {
  private prefStore: preferences.Preferences | null = null;

  async init(context: common.UIAbilityContext): Promise<void> {
    this.prefStore = await preferences.getPreferences(context, PREF_NAME);
    const saved = await this.prefStore.get(THEME_KEY, 'pink');
    AppStorage.setOrCreate(THEME_KEY, saved as string);
    Logger.info(TAG, '主题初始化: %{public}s', saved as string);
  }

  setTheme(id: string): void {
    AppStorage.setOrCreate(THEME_KEY, id);
    if (this.prefStore) {
      this.prefStore.put(THEME_KEY, id).then(() => {
        return this.prefStore?.flush();
      }).catch((e: Error) => {
        Logger.warn(TAG, '主题持久化失败: %{public}s', JSON.stringify(e));
      });
    }
  }

  /** 按 id 取主题；未知 id 回退默认 */
  getById(id: string): AppTheme {
    for (const theme of THEMES) {
      if (theme.id === id) {
        return theme;
      }
    }
    return THEMES[0];
  }

  /** 通用偏好读取（与主题共用 app_settings 文件，供网格密度等设置持久化） */
  async getPref<T extends preferences.ValueType>(key: string, defaultValue: T): Promise<T> {
    if (!this.prefStore) {
      return defaultValue;
    }
    const value = await this.prefStore.get(key, defaultValue);
    return value as T;
  }

  /** 通用偏好写入并落盘（设置变更后持久化） */
  putPref(key: string, value: preferences.ValueType): void {
    if (!this.prefStore) {
      return;
    }
    this.prefStore.put(key, value).then(() => {
      return this.prefStore?.flush();
    }).catch((e: Error) => {
      Logger.warn(TAG, '偏好持久化失败: %{public}s', JSON.stringify(e));
    });
  }
}

/** 模块级单例 */
export const themeManager: ThemeManager = new ThemeManager();
