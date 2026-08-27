import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;

/** 统一日志封装：固定 domain，tag 由调用方指定，避免各处散落魔数 */
export class Logger {
  static info(tag: string, fmt: string, ...args: Object[]): void {
    hilog.info(DOMAIN, tag, fmt, ...args);
  }

  static warn(tag: string, fmt: string, ...args: Object[]): void {
    hilog.warn(DOMAIN, tag, fmt, ...args);
  }

  static error(tag: string, fmt: string, ...args: Object[]): void {
    hilog.error(DOMAIN, tag, fmt, ...args);
  }
}
