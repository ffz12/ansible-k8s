# Git 操作说明（ansible-k8s 仓库）

> 本仓库使用 **Git LFS** 管理离线二进制（Harbor 镜像、各系统离线包等），`.git` 体积较大（约 4G），克隆/拉取时请注意下面的 LFS 相关说明。

---

## 一、克隆仓库

### 1. 完整克隆（含所有 LFS 大文件，约需下载 4G+）
```bash
git clone <仓库地址>
```

### 2. 只要代码、暂不下载 LFS 大文件（推荐日常开发）
```bash
GIT_LFS_SKIP_SMUDGE=1 git clone <仓库地址>
# 之后需要某些离线包时再按需拉取：
git lfs pull --include="offline/artifacts/harbor/x86/*"
```

### 3. 浅克隆（只取最新版本，不要历史）
```bash
git clone --depth=1 <仓库地址>
```

### 4. 按需排除部分 LFS 目录（不下用不到的离线包，省空间）

先跳过所有 LFS 克隆，再拉取"除排除项外"的 LFS：
```bash
GIT_LFS_SKIP_SMUDGE=1 git clone <仓库地址>
cd ansible-k8s
git lfs pull --exclude="offline/artifacts/ios-offline/*,offline/artifacts/dcu/*,offline/artifacts/nginx-ha/*,offline/artifacts/npu/*,offline/ansible-pkg-install/*"
```
上例排除 ios-offline / dcu / nginx-ha / npu / ansible-pkg-install（约省 1.85G），仍会下载 harbor / containerd / runc 等。

让排除**永久生效**（之后 pull/checkout 都跳过）：
```bash
git config lfs.fetchexclude "offline/artifacts/ios-offline/*,offline/artifacts/dcu/*,offline/artifacts/nginx-ha/*,offline/artifacts/npu/*,offline/ansible-pkg-install/*"
# 取消: git config --unset lfs.fetchexclude
```

反向——**只拉本机需要的**（更精准）：
```bash
GIT_LFS_SKIP_SMUDGE=1 git clone <仓库地址> && cd ansible-k8s
git lfs pull --include="offline/artifacts/harbor/*,offline/artifacts/containerd/*,offline/artifacts/runc/*"
```

> 各 LFS 目录大小参考：ios-offline ~1.5G、harbor ~2G、ansible-pkg-install ~269M、
> nginx-ha ~55M、npu ~20M、dcu ~8.5M、containerd ~157M、runc ~21M。

---

## 二、Git LFS 操作

```bash
# 安装并初始化 LFS（首次使用）
git lfs install

# 查看哪些文件被 LFS 管理及其大小
git lfs ls-files -s

# 拉取全部 LFS 文件
git lfs pull

# 按目录/模式拉取部分 LFS 文件
git lfs pull --include="offline/artifacts/ios-offline/*"

# 查看 LFS 跟踪规则（即 .gitattributes 里配置的）
git lfs track

# 新增一类大文件到 LFS 跟踪（示例：所有 .tar.gz）
git lfs track "*.tar.gz"
git add .gitattributes
```

### 清理本地 LFS 缓存（省磁盘）
```bash
git lfs prune        # 清掉历史中不再被引用的旧 LFS 版本
git gc               # 压缩普通 git 对象
```

---

## 三、提交本次 playbook 修复

```bash
# 1. 查看改动
git status
git diff                      # 看具体改了什么

# 2. 暂存改动（注意：只提交 playbook/配置，别误把大文件改动带上）
git add ansible.cfg playbook/

# 3. 提交
git commit -m "fix: 修复 playbook 多处 bug 与不规范写法

- nginx-ha/install-binary.yml 修复 YAML 解析失败（裸文本行）
- container-toolkit 统一 accelerator_type npu/ascend
- harbor/ssl.yaml 修复路径斜杠并加证书生成幂等保护
- change_yum/gpu-init 增加幂等守卫
- docker 检测命令、cri-dockerd/update-docker-daemon 任务名修正
- harbor-install/deploy-trust-harbor 补 become
- keepalived priority 改用 lb_upstream_servers
- 其余: chrony 服务名按发行版区分、nofile 值、删除 .bak 等"

# 4. 推送（首次推送当前分支到远端）
git push
# 若是新分支：
git push -u origin <分支名>
```

---

## 四、分支操作

```bash
git branch                          # 查看本地分支
git checkout -b fix/playbook-bugs   # 新建并切换到修复分支（推荐改动走分支）
git checkout main                   # 切回主分支
git merge fix/playbook-bugs         # 合并分支
```

> 建议：本次修复先在 `fix/playbook-bugs` 分支提交，验证（syntax-check / 测试环境跑通）后再合并到主分支。

---

## 五、查看与回滚

```bash
git log --oneline -20               # 最近 20 条提交
git log -p playbook/roles/harbor/tasks/ssl.yaml   # 看某文件的改动历史

# 撤销工作区未暂存的改动（恢复到最近一次提交）
git checkout -- <文件>
git restore <文件>                  # 新写法

# 撤销已暂存（git add 过）但未提交的改动
git restore --staged <文件>

# 回退到某次提交（保留改动到工作区）
git reset --soft <commit-id>
# 彻底回退（丢弃改动，慎用）
git reset --hard <commit-id>
```

---

## 六、本仓库特别注意

1. **不要把解压出来的临时文件、构建产物提交进去**。`offline/` 下的大包已用 LFS 管理，新增大文件前先确认 `.gitattributes` 是否已覆盖其类型，否则会以普通文件进库导致 `.git` 暴涨。
2. **提交前用 `git status` 确认改动范围**，避免误提交 `tmp/`、`*.bak`、本地证书（`roles/certs/files/` 下的 `*-key.pem` 等私钥**不应**进公共仓库）。
3. 磁盘紧张时：工作区 `offline/`（4.2G）+ `.git/lfs`（3.6G）会占双份空间；只用包不做 git 操作时，可 `git lfs prune` 清缓存。
4. **私钥风险**：`roles/certs/files/etcd-default/*-key.pem` 是 etcd 证书私钥，已在仓库里。若是生产环境，建议改为部署时动态生成、并把私钥加入 `.gitignore`，不要随仓库分发。

---

## 七、常用速查

| 操作 | 命令 |
|---|---|
| 看状态 | `git status` |
| 看改动 | `git diff` |
| 暂存 | `git add <文件>` / `git add .` |
| 提交 | `git commit -m "说明"` |
| 推送 | `git push` |
| 拉取 | `git pull` |
| 拉 LFS | `git lfs pull` |
| 看 LFS 文件 | `git lfs ls-files -s` |
| 清 LFS 缓存 | `git lfs prune` |
| 新建分支 | `git checkout -b <名>` |
| 看历史 | `git log --oneline` |
