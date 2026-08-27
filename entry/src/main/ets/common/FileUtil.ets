import { fileIo as fs } from '@kit.CoreFileKit';

/**
 * 通用文件工具：复制/删除/递归遍历/文件名提取。
 * 原实现分散在 BackupService / ImportService / ModelScanner / ThumbnailService，
 * 统一收敛到此处，后续文件操作只改一个地方。
 */
export class FileUtil {
  /** 复制文件（源可为 Picker URI，目标可为普通路径；用文件句柄绕过 URI 协议差异） */
  static async copyFile(srcPath: string, destPath: string): Promise<void> {
    const src = fs.openSync(srcPath, fs.OpenMode.READ_ONLY);
    const dest = fs.openSync(destPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      const buffer = new ArrayBuffer(1024 * 1024);
      let readLen = fs.readSync(src.fd, buffer);
      while (readLen > 0) {
        const slice = buffer.slice(0, readLen);
        fs.writeSync(dest.fd, slice);
        readLen = fs.readSync(src.fd, buffer);
      }
    } finally {
      fs.closeSync(src);
      fs.closeSync(dest);
    }
  }

  /** 递归复制目录（源不存在则跳过；目标目录不存在则创建） */
  static async copyDir(srcDir: string, destDir: string): Promise<void> {
    if (!fs.accessSync(srcDir)) {
      return;
    }
    if (!fs.accessSync(destDir)) {
      await fs.mkdir(destDir, true);
    }
    const entries = fs.listFileSync(srcDir);
    for (const name of entries) {
      const src = `${srcDir}/${name}`;
      const dest = `${destDir}/${name}`;
      if (fs.statSync(src).isDirectory()) {
        await FileUtil.copyDir(src, dest);
      } else {
        await FileUtil.copyFile(src, dest);
      }
    }
  }

  /** 递归删除目录（含全部内容；目录不存在则直接返回） */
  static async removeDir(dir: string): Promise<void> {
    if (!fs.accessSync(dir)) {
      return;
    }
    const entries = fs.listFileSync(dir);
    for (const name of entries) {
      const full = `${dir}/${name}`;
      if (fs.statSync(full).isDirectory()) {
        await FileUtil.removeDir(full);
      } else {
        fs.unlinkSync(full);
      }
    }
    fs.rmdirSync(dir);
  }

  /** 递归收集指定后缀的文件（全路径列表） */
  static listFilesRecursive(dir: string, suffix: string): string[] {
    const out: string[] = [];
    try {
      const entries = fs.listFileSync(dir);
      for (const name of entries) {
        const full = `${dir}/${name}`;
        const stat = fs.statSync(full);
        if (stat.isDirectory()) {
          out.push(...FileUtil.listFilesRecursive(full, suffix));
        } else if (name.endsWith(suffix)) {
          out.push(full);
        }
      }
    } catch (e) {
      // 遍历异常（目录被并发删除等）跳过该目录
    }
    return out;
  }

  /** 递归收集全部子目录（含深层，不含根自身） */
  static listDirsRecursive(dir: string): string[] {
    const out: string[] = [];
    try {
      const entries = fs.listFileSync(dir);
      for (const name of entries) {
        const full = `${dir}/${name}`;
        const stat = fs.statSync(full);
        if (stat.isDirectory()) {
          out.push(full);
          out.push(...FileUtil.listDirsRecursive(full));
        }
      }
    } catch (e) {
      // 遍历异常跳过
    }
    return out;
  }

  /** 取路径末段（basename）；无分隔符时原样返回 */
  static basename(path: string): string {
    const idx = path.lastIndexOf('/');
    return idx >= 0 ? path.substring(idx + 1) : path;
  }

  /** 从 Picker URI 提取可读文件名（去查询串 + 取末段 + 解码）；空则返回 fallback */
  static displayName(uri: string, fallback: string): string {
    const noQuery = uri.split('?')[0];
    const seg = decodeURIComponent(noQuery.substring(noQuery.lastIndexOf('/') + 1));
    return seg !== '' ? seg : fallback;
  }
}