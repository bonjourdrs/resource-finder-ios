# Resource Finder Android Beta4 — GitHub 免费构建入口

这个公开仓库的工作流仅作为 **Resource Finder 项目跨平台构建入口**。
**Android 源码及原有签名材料仍留在 `bonjourdrs/codex-test` 私有仓库**。
这个公开仓库不存储私有源码、APK 签名文件、API Token 或解压后的构建目录。

## 一次性准备（需要仓库所有者操作）

1. 登录 GitHub，打开 https://github.com/settings/personal-access-tokens/new ，创建 fine-grained Personal Access Token。
   - Resource owner: `bonjourdrs`
   - Repository access: **Only select repositories → `codex-test`**
   - Repository permissions: **Contents → Read-only**（Metadata 默认 read）
   - 设短有效期（如 7 天）；不授予写入、管理、Actions 或其他仓库权限。
2. 打开 https://github.com/bonjourdrs/resource-finder-ios/settings/secrets/actions/new ，新建 repository Actions secret：
   - Name：`RF_PRIVATE_REPO_READ_TOKEN`
   - Secret：上一步创建的令牌。
   - **不要**把令牌发到聊天、Issues、代码、日志或 Workflow Inputs。
3. 打开 https://github.com/bonjourdrs/resource-finder-ios/actions/workflows/build-resource-finder-android-beta4.yml
   → **Run workflow** → 分支 `main` → **Run workflow**。
4. 成功后，在该运行记录下载 `Resource-Finder-v1.4.0-beta4-android` Artifact，
   内含原签名 APK 与 SHA-256 校验文件。

## 安全边界

- 仅接受仓库所有者手动触发或修改本工作流文件时的推送，不接收 PR 触发。
- Checkout 私有仓库时关闭 persist-credentials，凭据仅供 checkout 操作。
- GitHub-hosted runner 在工作流结束后销毁。
- 仓库为**公开**，运行日志和最终 APK Artifact 可能被他人读取；
  不在 Artifact 中上传源代码、签名密钥、私有 checkout 或测试报告。
- 使用原有签名证书，校验包名 `com.resourcefinder.standalone`、
  versionCode 143、versionName `1.4.0-beta4`、签名 SHA-256
  `73878e388879a837760bb3c500ff415d0ce54f92cf36b8421557abcf98cfdcf4`。
- 工作流仅完成 Android JVM 单测、APK 编译与签名校验；
  **不等于手机/Android TV 模拟器全套测试已通过**。
- 对 Gradle 插件及第三方依赖使用标准 GitHub Actions；请勿在不可信的 PR 工作流中授予上述 Secret。

## 构建未通过时

- `Missing Actions secret RF_PRIVATE_REPO_READ_TOKEN`：检查 Secret 是否配置到 `resource-finder-ios` 这个公开仓库（不是 `codex-test`）。
- `Repository not found` / 403：检查 PAT 是否仍有效、是否选择 `codex-test`、Contents Read-only。
- Kotlin/Gradle 测试失败：需要根据 GitHub 运行日志修复源码后重跑，不能声称 APK 已生成。

只要令牌没有配置，工作流会在读取任何私有资源之前直接终止。
