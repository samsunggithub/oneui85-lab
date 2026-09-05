# r12s 补丁工作包

`Build Star7ROM` 的 `patch_test` 模式用于验证 **S24 FE（r12s）One UI 8.5 源端 APK/JAR 补丁**。它只面向 `d2xks`，不下载目标固件、不构建分区镜像，也不生成 ROM ZIP。

每次补丁测试都会发布一个 `r12s-patch-test-<run-number>` Artifact。Artifact 中的 `SM-S721B_EUX` 目录是可复用的最小工作包，包含当前会触发源端补丁的 framework、APK、属性、VNDK APEX 元数据和 overlay 输入；它不包含完整固件树。

从工作包 **v2** 起，资源清单还包含 DAAgent、MotionPhoto、Knox SDK、Samsung Keystore Utils、SecSettingsIntelligence 和 StorageManager。测试会按生产顺序连续应用对应的 `unica` 与 Exynos 9825 静态 Smali 补丁，再对所有已解码目标回编。测试同时检查当前 d2xks 构建会读取的预编译来源，并在 b0s 蓝牙 APEX 上验证 JNI 库的无挂载提取、文件元数据和字节替换。

## 本地验证

下载某次 Artifact 后，在仓库根目录运行：

```bash
gh run download <run-id> --repo samsunggithub/Star7-ROM \
  --name r12s-patch-test-<run-number> \
  --dir /path/to/r12s-patch-work

PATCH_TEST_MODE=true ./scripts/test_patch_fixture.sh \
  --fixture /path/to/r12s-patch-work/SM-S721B_EUX \
  --output out/patch-test/d2xks \
  --keep-work-dir
```

首次本地运行只会准备 apktool 与 smali 所需工具；之后可复用 `out/tools`。`PATCH_TEST_MODE=true` 仍会解码并回编实际 APK/JAR，但会跳过签名和 zipalign，因为该模式只验证补丁锚点、Smali/资源变更和回编兼容性，而不是生成可刷写产物。

成功后，`out/patch-test/d2xks/report` 包含变更前后校验和、测试配置及 `bluetooth-patch.properties`。`fixture.properties` 中的 `FIXTURE_REVISION` 与 `FIXTURE_STATIC_SMALI_TARGETS` 用于区分工作包覆盖范围；v1 Artifact 仍可复用，但不会执行 v2 的静态 Smali 序列。若失败，Artifact 的 `report/failure.txt` 会记录失败模块、已经解码的目标及聚焦候选 Smali；报告同时保存相关 SecSettings 与 SystemUI Smali 副本，供本地重建 One UI 8.5 锚点。

> 本地夹具测试通过是推送补丁的前置条件，但不能替代最终的 d2xks 远程 ROM 构建验证。只有在本地补丁应用和回编通过后，才应推送独立提交并触发远程复核。
