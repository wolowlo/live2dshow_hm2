class L2D {
    constructor (basePath, textureScale) {
        this.basePath = basePath;
        this.loader = new PIXI.loaders.Loader(this.basePath);
        this.animatorBuilder = new LIVE2DCUBISMFRAMEWORK.AnimatorBuilder();
        this.timeScale = 1;
        this.models = {};
        this.physicsEnabled = false;
        // 纹理降采样系数：0 < x < 1 时把加载的贴图等比缩小后送入 GPU，
        // 用于小尺寸卡片预览（舞台全清传 1），降低显存占用与采样带宽
        this.textureScale = textureScale && textureScale > 0 && textureScale < 1 ? textureScale : 1;
    }

    /** 将纹理贴图按 textureScale 缩小重绘到小画布，替换 baseTexture.source 后重新上传 */
    _downscaleTexture (texture) {
        const base = texture.baseTexture;
        const src = base.source;
        if (!src || !src.width || !src.height) return texture;
        const w = Math.max(2, Math.round(src.width * this.textureScale));
        const h = Math.max(2, Math.round(src.height * this.textureScale));
        const canvas = document.createElement('canvas');
        canvas.width = w;
        canvas.height = h;
        canvas.getContext('2d').drawImage(src, 0, 0, w, h);
        const frame = texture.frame;
        base.source = canvas;
        base.width = w;
        base.height = h;
        if (frame) {
            // 同步缩放 UV 裁剪区，避免采样越界
            texture.frame = new PIXI.Rectangle(
                frame.x * this.textureScale,
                frame.y * this.textureScale,
                frame.width * this.textureScale,
                frame.height * this.textureScale,
            );
            texture._updateUvs();
        }
        base.update();
        return texture;
    }
    
    setPhysics3Json (value) {
        if (value == null) {
            // physics3.json 缺失或加载失败：跳过物理模拟
            return this;
        }
        if (!this.physicsRigBuilder) {
            this.physicsRigBuilder = new LIVE2DCUBISMFRAMEWORK.PhysicsRigBuilder();
        }
        this.physicsRigBuilder.setPhysics3Json(value);
        this.physicsEnabled = true;

        return this;
    }
    
    load (name, v) {
        if (!this.models[name]) {
            let modelDir = name+'/';
            name = name.split('/').pop();
            let modelPath = name+'.model3.json';
            let textures = new Array();
            let textureCount = 0;
            let motionNames = new Array();

            this.loader.add(name+'_model', modelDir+modelPath, { xhrType: PIXI.loaders.Resource.XHR_RESPONSE_TYPE.JSON });

            this.loader.load((loader, resources) => {
                let model3Obj = resources[name+'_model'].data;

                if (model3Obj == null) {
                    console.error('[L2D] model3.json 加载失败: ' + modelDir+modelPath);
                    return;
                }
                
                let fr = model3Obj['FileReferences'];
                if (typeof(fr) !== "object" || fr == null) {
                    console.error('[L2D] model3.json 缺少 FileReferences: ' + modelDir+modelPath);
                    return;
                }

                if (typeof(fr['Moc']) === "string") {
                    loader.add(name+'_moc', modelDir+fr['Moc'], { xhrType: PIXI.loaders.Resource.XHR_RESPONSE_TYPE.BUFFER });
                }

                if (Array.isArray(fr['Textures'])) {
                    fr['Textures'].forEach((element) => {
                        if (typeof(element) === "string") {
                            loader.add(name+'_texture'+textureCount, modelDir+element);
                            textureCount++;
                        }
                    });
                }

                if (typeof(fr['Physics']) === "string") {
                    loader.add(name+'_physics', modelDir+fr['Physics'], { xhrType: PIXI.loaders.Resource.XHR_RESPONSE_TYPE.JSON });
                }

                if (typeof(fr['Motions']) === "object" && fr['Motions'] != null) {
                    for (let group in fr['Motions']) {
                        if (!Array.isArray(fr['Motions'][group])) continue;
                        fr['Motions'][group].forEach((element) => {
                            if (typeof(element) !== "object" || element == null || typeof(element['File']) !== "string") return;
                            let motionName = element['File'].split('/').pop().split('.').shift();
                            // 同一 motion 文件可能被多个分组引用（如 Sleeping 出现在 Taphead/Tick_5），资源名需去重
                            let resName = name+'_'+motionName;
                            let dup = 1;
                            while (loader.resources[resName]) {
                                resName = name+'_'+motionName+'_'+(dup++);
                            }
                            loader.add(resName, modelDir+element['File'], { xhrType: PIXI.loaders.Resource.XHR_RESPONSE_TYPE.JSON });
                            motionNames.push(resName);
                        });
                    }
                }

                let groups = null;
                if (model3Obj['Groups'] && typeof(model3Obj['Groups']) === "object") {
                    groups = LIVE2DCUBISMFRAMEWORK.Groups.fromModel3Json(model3Obj);
                }

                loader.load((l, r) => {
                    let moc = null;
                    if (typeof(r[name+'_moc']) !== "undefined") {
                        moc = Live2DCubismCore.Moc.fromArrayBuffer(r[name+'_moc'].data);
                    }

                    if (typeof(r[name+'_texture'+0]) !== "undefined") {
                        for (let i = 0; i < textureCount; i++) {
                            let tex = r[name+'_texture'+i].texture;
                            if (this.textureScale < 1) tex = this._downscaleTexture(tex);
                            textures.splice(i, 0, tex);
                        }
                    }

                    if (typeof(r[name+'_physics']) !== "undefined") {
                        this.setPhysics3Json(r[name+'_physics'].data);
                    }

                    let motions = new Map();
                    motionNames.forEach((element) => {
                        let n = element.split(name+'_').pop();
                        motions.set(n, LIVE2DCUBISMFRAMEWORK.Animation.fromMotion3Json(r[element].data));
                    });

                    let model = null;
                    let coreModel = Live2DCubismCore.Model.fromMoc(moc);
                    if (coreModel == null) {
                        return;
                    }

                    let animator = this.animatorBuilder
                        .setTarget(coreModel)
                        .setTimeScale(this.timeScale)
                        .build();

                    let physicsRig = null;
                    if (this.physicsEnabled) {
                        physicsRig = this.physicsRigBuilder
                            .setTarget(coreModel)
                            .setTimeScale(this.timeScale)
                            .build();
                    }

                    let userData = null;

                    model = LIVE2DCUBISMPIXI.Model._create(coreModel, textures, animator, physicsRig, userData, groups);
                    model.motions = motions;
                    // 挂载 HitAreas（点击命中检测用）：l2d.js 加载阶段读取 model3.json
                    model.hitAreas = Array.isArray(model3Obj['HitAreas']) ? model3Obj['HitAreas'] : [];
                    this.models[name] = model;

                    v.changeCanvas(model);
                });
            });
        } else {
            v.changeCanvas(this.models[name]);
        }
    }
}
