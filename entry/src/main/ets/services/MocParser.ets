import { fileIo as fs } from '@kit.CoreFileKit';
import { Logger } from '../common/Logger';

const TAG = 'MocParser';

// 对象类型号（与 Live2D 官方枚举一致，移植自原项目 services.py）
const MOC_T_NULL = 0;
const MOC_T_STRING = 1;
const MOC_T_OBJ_ARRAY = 15;
const MOC_T_INT_ARRAY = 16;
const MOC_T_INT_ARRAY2 = 25;
const MOC_T_DOUBLE_ARRAY = 26;
const MOC_T_FLOAT_ARRAY = 27;
const MOC_T_OBJ_REF = 33;
const MOC_T_DRAW_ID = 50;
const MOC_T_BASE_ID = 51;
const MOC_T_PARAM_ID = 60;
const MOC_T_CURVED = 65;
const MOC_T_PIVOT_MGR = 66;
const MOC_T_PARAM_PIVOTS = 67;
const MOC_T_ROTATION = 68;
const MOC_T_AFFINE = 69;
const MOC_T_DD_TEXTURE = 70;
const MOC_T_PARAM_DEF_F = 131;
const MOC_T_PARTS = 133;
const MOC_T_PARTS_ID = 134;
const MOC_T_MODEL_IMPL = 136;
const MOC_T_PARAM_DEF_LIST = 137;
const MOC_T_AVATAR = 142;
const MOC_V2_10 = 10;

/** Cubism 2 .moc 画布尺寸 */
export interface MocCanvasSize {
  width: number;
  height: number;
}

/**
 * .moc 字节流读取器（Big-Endian + 高位优先变长整数 + 位读取）。
 * 只“跳过”对象图不构建对象，用于取 canvas 尺寸：头部 ModelImpl → Params → Parts → width → height。
 */
class MocReader {
  private view: DataView;
  private pos: number;
  private version: number;
  private bitPos: number;
  private bitBuf: number;
  private depth: number;

  constructor(data: ArrayBuffer) {
    this.view = new DataView(data);
    this.pos = 4; // 跳过 magic(3) + version(1)
    this.version = data.byteLength > 3 ? new Uint8Array(data)[3] : 0;
    this.bitPos = 0;
    this.bitBuf = 0;
    this.depth = 0;
  }

  private u8(): number {
    const b = this.view.getUint8(this.pos);
    this.pos += 1;
    return b;
  }

  /** 高位优先变长整数：(b0&0x7F)<<14 | (b1&0x7F)<<7 | b2 ... */
  number(): number {
    this.bitPos = 0;
    const b0 = this.u8();
    if (b0 < 0x80) {
      return b0;
    }
    const b1 = this.u8();
    if (b1 < 0x80) {
      return ((b0 & 0x7F) << 7) | b1;
    }
    const b2 = this.u8();
    if (b2 < 0x80) {
      return ((b0 & 0x7F) << 14) | ((b1 & 0x7F) << 7) | b2;
    }
    const b3 = this.u8();
    return ((b0 & 0x7F) << 21) | ((b1 & 0x7F) << 14) | ((b2 & 0x7F) << 7) | b3;
  }

  private bit(): number {
    if (this.bitPos === 0) {
      this.bitBuf = this.u8();
    }
    const b = (this.bitBuf >> (7 - this.bitPos)) & 1;
    this.bitPos = (this.bitPos + 1) % 8;
    return b;
  }

  i32(): number {
    this.bitPos = 0;
    const v = this.view.getInt32(this.pos, false);
    this.pos += 4;
    return v;
  }

  private skip(n: number): void {
    this.bitPos = 0;
    this.pos += n;
  }

  private utf8(): void {
    this.skip(this.number());
  }

  private intArray(): void {
    this.skip(4 * this.number());
  }

  private floatArray(): void {
    this.skip(4 * this.number());
  }

  private doubleArray(): void {
    this.skip(8 * this.number());
  }

  readObject(): void {
    if (this.depth >= 64) {
      throw new Error('moc object too deep');
    }
    this.depth += 1;
    try {
      this.readObjectInner();
    } finally {
      this.depth -= 1;
    }
  }

  private readObjectInner(): void {
    const t = this.number();
    if (t === MOC_T_OBJ_REF) {
      this.i32();
      return;
    }
    if (t === MOC_T_NULL) {
      return;
    }
    if (t === MOC_T_STRING || t === MOC_T_DRAW_ID || t === MOC_T_BASE_ID ||
      t === MOC_T_PARAM_ID || t === MOC_T_PARTS_ID) {
      this.utf8();
      return;
    }
    if (t === MOC_T_OBJ_ARRAY) {
      const n = this.number();
      for (let i = 0; i < n; i++) {
        this.readObject();
      }
      return;
    }
    if (t === MOC_T_INT_ARRAY || t === MOC_T_INT_ARRAY2) {
      this.intArray();
      return;
    }
    if (t === MOC_T_FLOAT_ARRAY) {
      this.floatArray();
      return;
    }
    if (t === MOC_T_DOUBLE_ARRAY) {
      this.doubleArray();
      return;
    }
    if (t === MOC_T_PARAM_DEF_LIST || t === MOC_T_PIVOT_MGR) {
      this.readObject();
      return;
    }
    if (t === MOC_T_PARAM_DEF_F) {
      this.skip(12);
      this.readObject();
      return;
    }
    if (t === MOC_T_PARAM_PIVOTS) {
      this.readObject();
      this.i32();
      this.readObject();
      return;
    }
    if (t === MOC_T_AFFINE) {
      this.skip(20);
      if (this.version >= MOC_V2_10) {
        this.u8();
        this.u8();
      }
      return;
    }
    if (t === MOC_T_PARTS) {
      this.bit();
      this.bit();
      this.readObject();
      this.readObject();
      this.readObject();
      return;
    }
    if (t === MOC_T_CURVED) {
      this.readObject();
      this.readObject();
      this.i32();
      this.i32();
      this.readObject();
      this.readObject();
      if (this.version >= MOC_V2_10) {
        this.floatArray();
      }
      return;
    }
    if (t === MOC_T_ROTATION) {
      this.readObject();
      this.readObject();
      this.readObject();
      this.readObject();
      if (this.version >= MOC_V2_10) {
        this.floatArray();
      }
      return;
    }
    if (t === MOC_T_DD_TEXTURE) {
      this.readObject();
      this.readObject();
      this.readObject();
      this.i32();
      this.intArray();
      this.floatArray();
      if (this.version >= 11) {
        this.readObject();
      }
      this.i32();
      this.i32();
      this.i32();
      this.readObject(); // IndexArray
      this.readPoints(); // PivotPoints
      this.readObject(); // UvMap
      if (this.version >= 8) {
        const flag = this.i32();
        if ((flag & 1) !== 0) {
          this.i32();
        }
      }
      return;
    }
    if (t === MOC_T_AVATAR) {
      this.readObject();
      this.readObject();
      this.readObject();
      this.readObject();
      return;
    }
    throw new Error(`unknown moc type ${t}`);
  }

  private readPoints(): void {
    const t = this.number();
    if (t === MOC_T_OBJ_REF) {
      this.i32();
      return;
    }
    if (t === MOC_T_NULL) {
      return;
    }
    if (t === MOC_T_OBJ_ARRAY) {
      const n = this.number();
      for (let i = 0; i < n; i++) {
        const t2 = this.number();
        if (t2 === MOC_T_FLOAT_ARRAY) {
          this.floatArray();
        } else if (t2 === MOC_T_OBJ_REF) {
          this.i32();
        } else if (t2 !== MOC_T_NULL) {
          throw new Error('unknown points elem type');
        }
      }
      return;
    }
    if (t === MOC_T_FLOAT_ARRAY) {
      this.floatArray();
      return;
    }
    if (t !== MOC_T_NULL) {
      throw new Error('unknown points type');
    }
  }
}

/** 解析 .moc 文件画布尺寸；文件缺失/格式错误返回 null */
export function parseMocCanvasSize(path: string): MocCanvasSize | null {
  let file: fs.File | null = null;
  try {
    file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    const size = fs.statSync(file.fd).size;
    if (size < 4) {
      return null;
    }
    const buffer = new ArrayBuffer(size);
    fs.readSync(file.fd, buffer);
    const bytes = new Uint8Array(buffer);
    if (bytes[0] !== 0x6d || bytes[1] !== 0x6f || bytes[2] !== 0x63) {
      return null;
    }
    const reader = new MocReader(buffer);
    if (reader.number() !== MOC_T_MODEL_IMPL) {
      return null;
    }
    reader.readObject(); // Params
    reader.readObject(); // Parts
    const width = reader.i32();
    const height = reader.i32();
    if (width > 0 && height > 0) {
      return { width, height };
    }
    return null;
  } catch (e) {
    Logger.warn(TAG, 'moc 解析失败: %{public}s', path);
    return null;
  } finally {
    if (file) {
      try {
        fs.closeSync(file);
      } catch (e) {
        Logger.warn(TAG, '关闭 moc 失败: %{public}s', path);
      }
    }
  }
}
