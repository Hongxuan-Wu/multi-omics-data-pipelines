# Codex bwrap / AppArmor 问题记录

日期：2026-07-01

## 1. 现象

Codex 在本机执行任何本地命令时失败，包括：

```bash
true
git status --short
git add -A
```

典型报错：

```text
bwrap: setting up uid map: Permission denied
```

这说明命令还没有真正执行，失败发生在 Codex Linux sandbox 初始化阶段。

## 2. 根因判断

已确认：

| 检查项 | 结果 | 结论 |
|---|---:|---|
| `kernel.unprivileged_userns_clone` | `1` | 内核允许普通用户创建 user namespace |
| `user.max_user_namespaces` | 非 0 | user namespace 数量限制正常 |
| `kernel.apparmor_restrict_unprivileged_userns` | `1` | Ubuntu/AppArmor 正在限制未授权程序使用 user namespace |
| `unshare -Ur true` | `Operation not permitted` | 普通程序仍被 AppArmor 限制 |

最佳判断：问题不是 Git、conda 或项目权限，而是 Ubuntu 24.04 的 AppArmor restricted unprivileged user namespaces 机制拦截了 Codex 使用的 `bubblewrap`。

## 3. 已验证修复

给 `/usr/bin/bwrap` 添加 AppArmor profile，允许它使用 `userns`：

```bash
sudo tee /etc/apparmor.d/usr.bin.bwrap >/dev/null <<'EOF'
abi <abi/4.0>,

include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(default_allow) {
  userns,

  include if exists <local/usr.bin.bwrap>
}
EOF

sudo apparmor_parser -r /etc/apparmor.d/usr.bin.bwrap
sudo systemctl reload apparmor
```

验证命令：

```bash
sudo -u p252701008 -H /usr/bin/bwrap \
  --unshare-user --uid 0 --gid 0 \
  --ro-bind / / \
  /usr/bin/id
```

成功输出示例：

```text
uid=0(root) gid=0(root) groups=0(root),65534(nogroup)
```

注意：`unshare -Ur true` 仍可能失败，这是正常的，因为只给 `/usr/bin/bwrap` 放行，没有给 `/usr/bin/unshare` 放行。

## 4. 修复后的剩余限制

bwrap 修复后，Codex 已能运行本地命令，例如 `git status --short`。

但执行 `git add -A` 仍失败：

```text
fatal: Unable to create '.git/index.lock': Read-only file system
```

原因：当前 Codex 配置仍是 `sandbox_mode = workspace-write`，工作区文件可写，但 `.git` 目录在 sandbox 内是只读的，因此不能写入 `.git/index`，也就不能 stage 或 commit。

## 5. 后续解决路线

| 目标 | 方案 | 风险 |
|---|---|---|
| 只恢复命令执行 | 保留 bwrap AppArmor profile | 低 |
| 让 Codex 能 `git add` / `git commit` | 调整 Codex 权限或手动在终端执行 Git | 中 |
| 临时让 Codex 完全操作 Git | `sandbox_mode = "danger-full-access"` + `approval_policy = "on-request"` | 中高 |
| 长期安全方案 | 保持 `workspace-write`，Git 操作由用户手动执行或使用受控审批机制 | 低 |

## 6. 推荐操作

如果再次遇到 `bwrap: setting up uid map: Permission denied`：

1. 检查 `/etc/apparmor.d/usr.bin.bwrap` 是否存在。
2. 运行：

```bash
sudo apparmor_parser -r /etc/apparmor.d/usr.bin.bwrap
sudo systemctl reload apparmor
```

3. 用 `/usr/bin/bwrap` 测试，不要用 `unshare` 测试：

```bash
sudo -u p252701008 -H /usr/bin/bwrap \
  --unshare-user --uid 0 --gid 0 \
  --ro-bind / / \
  /usr/bin/id
```

4. 完全退出并重启 Codex。

如果只是需要提交当前项目：

```bash
cd /data/p252701008/projects/multi-omics-data-pipelines
git add -A
git commit -m "添加-RefSeq全量下载脚本"
```
