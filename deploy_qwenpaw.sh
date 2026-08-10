#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  QwenPaw Termux 后端 · 一键部署脚本
#  ------------------------------------------------------------
#  适用：全新 Termux 环境（Android 手机，无需 root）
#  用法：bash deploy_qwenpaw.sh
#  产物：Termux 后端 + qwenpaw + 一键启动脚本 start_qwenpaw.sh
#  说明：脚本可重复执行（幂等），中断后重跑即可续传
# ============================================================
set -e

export HOME=/data/data/com.termux/files/home
export PREFIX=/data/data/com.termux/files/usr
export PATH="$PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/lib"

LOG="$HOME/qwenpaw_deploy.log"
UBUNTU_CMD="proot-distro login ubuntu --"

echo "=============================================="
echo "  QwenPaw Termux 后端一键部署"
echo "  预计耗时：30~60 分钟（下载安装依赖）"
echo "  日志：$LOG"
echo "=============================================="

# ------------------------------------------------------------
# [1/7] 安装 proot-distro
# ------------------------------------------------------------
echo ""
echo "[1/7] 检查/安装 proot-distro ..."
if ! command -v proot-distro >/dev/null 2>&1; then
    echo "    安装 proot-distro ..."
    pkg update -y 2>&1 | tail -2 >> "$LOG" || true
    pkg install -y proot-distro 2>&1 | tail -2 >> "$LOG"
fi
echo "    ✅ proot-distro: $(proot-distro --version 2>&1 | head -1 || echo '已安装')"

# ------------------------------------------------------------
# [2/7] 安装 Ubuntu（proot-distro 5.x OCI 方式）
# ------------------------------------------------------------
echo ""
echo "[2/7] 检查/安装 Ubuntu 环境（约 300MB）..."
if ! proot-distro list 2>/dev/null | grep -q '^ubuntu'; then
    echo "    正在安装 ubuntu，请耐心等待..."
    proot-distro install ubuntu 2>&1 | tail -5 >> "$LOG"
fi
echo "    ✅ Ubuntu 已就绪"

# ------------------------------------------------------------
# [3/7] Ubuntu 内安装 qwenpaw（Python 3.13 + uv + venv）
#        幂等：已存在 venv 则跳过
# ------------------------------------------------------------
echo ""
echo "[3/7] 安装 QwenPaw 本体（最耗时步骤）..."
$UBUNTU_CMD bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
export PATH=/root/.local/bin:/root/qwenpaw-venv/bin:$PATH

if [ -x /root/qwenpaw-venv/bin/qwenpaw ]; then
    echo "    ✅ qwenpaw 已安装，跳过"
    exit 0
fi

echo "    安装基础工具..."
apt-get update -qq 2>&1 | tail -1
apt-get install -y -qq curl python3-pip ca-certificates git 2>&1 | tail -1

echo "    安装 uv（Python 版本管理器）..."
pip3 install -q --break-system-packages uv 2>&1 | tail -1 || curl -LsSf https://astral.sh/uv/install.sh | sh

echo "    安装 Python 3.13（qwenpaw 需要 <3.14）..."
uv python install 3.13 2>&1 | tail -2

echo "    创建虚拟环境..."
uv venv /root/qwenpaw-venv --python 3.13 2>&1 | tail -1
/root/qwenpaw-venv/bin/python -m ensurepip 2>&1 | tail -1

echo "    安装 qwenpaw + 200 依赖（约 20-40 分钟）..."
/root/qwenpaw-venv/bin/python -m pip install -q --upgrade pip 2>&1 | tail -1
/root/qwenpaw-venv/bin/python -m pip install qwenpaw 2>&1 | tail -5

/root/qwenpaw-venv/bin/python -c "import qwenpaw; print(\"    ✅ qwenpaw 版本:\", getattr(qwenpaw, \"__version__\", \"2.x\"))"
' 2>&1 | tee -a "$LOG"

# ------------------------------------------------------------
# [4/7] 初始化 qwenpaw 工作目录
# ------------------------------------------------------------
echo ""
echo "[4/7] 初始化 QwenPaw 工作目录..."
$UBUNTU_CMD bash -c '
set -e
export PATH=/root/qwenpaw-venv/bin:$PATH
cd /root
if [ ! -f /root/.qwenpaw/workspaces/default/agent.json ]; then
    /root/qwenpaw-venv/bin/qwenpaw init --defaults --accept-security 2>&1 | tail -2
fi
echo "    ✅ 工作目录: /root/.qwenpaw"
' 2>&1 | tee -a "$LOG"

# ------------------------------------------------------------
# [5/7] 配置 DashScope API Key（pty 全自动）
# ------------------------------------------------------------
echo ""
echo "[5/7] 配置 DashScope API Key ..."
echo "    （没有 Key 请先到 https://bailian.console.aliyun.com/ 创建，sk- 开头）"
read -p "    粘贴你的 DashScope API Key: " DASH_KEY
if [ -z "$DASH_KEY" ]; then
    echo "    ⚠️ 未输入 Key，跳过自动配置。稍后可运行：qwenpaw models config-key dashscope"
else
    # 通过 pty 自动应答（在 Ubuntu 内用 python3 模拟终端）
    $UBUNTU_CMD bash -c "cat > /tmp/auto_key.py <<'PYEOF'
import os, pty, time, select, sys
def run(cmd, answers, gap=2.0, timeout=40):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ['PATH'] = '/root/qwenpaw-venv/bin:' + os.environ.get('PATH','')
        os.execvp(cmd[0], cmd)
    out=b''; idx=0; start=time.time()
    while time.time() < start+timeout:
        r,_,_ = select.select([fd],[],[],0.5)
        if r:
            try: d=os.read(fd,4096)
            except OSError: break
            if not d: break
            out+=d
        if idx < len(answers) and time.time()-start > (idx+1)*gap:
            try: os.write(fd, answers[idx].encode()+b'\\r')
            except OSError: pass
            idx+=1
    try: os.close(fd)
    except Exception: pass
run(['/root/qwenpaw-venv/bin/qwenpaw','models','config-key','dashscope'],
    ['https://dashscope.aliyuncs.com/compatible-mode/v1','$DASH_KEY'])
PYEOF
python3 /tmp/auto_key.py 2>&1 | grep -E '✓|Error|error' | tail -2
rm -f /tmp/auto_key.py"
    echo "    ✅ API Key 配置完成"
fi

# ------------------------------------------------------------
# [6/7] 生成一键启动脚本
# ------------------------------------------------------------
echo ""
echo "[6/7] 生成启动脚本 start_qwenpaw.sh ..."
cat > "$HOME/start_qwenpaw.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# QwenPaw 一键启动（在 Termux 里执行：bash ~/start_qwenpaw.sh）
export HOME=/data/data/com.termux/files/home
export PREFIX=/data/data/com.termux/files/usr
export PATH="$PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/lib"
echo "==> 启动 QwenPaw 后端 (http://127.0.0.1:8088)"
echo "    请保持本终端前台运行（后台会被系统限网）"
exec proot-distro login ubuntu -- bash -c 'export PATH=/root/qwenpaw-venv/bin:$PATH; cd /root; exec qwenpaw app --host 127.0.0.1 --port 8088'
EOF
chmod +x "$HOME/start_qwenpaw.sh"
echo "    ✅ $HOME/start_qwenpaw.sh"

# ------------------------------------------------------------
# [7/7] 完成
# ------------------------------------------------------------
echo ""
echo "=============================================="
echo "  ✅ 部署完成！"
echo "=============================================="
echo ""
echo "  【最后一步】配置活跃模型（聊天用哪个模型）"
echo "   在 Termux 执行："
echo "     proot-distro login ubuntu"
echo "     export PATH=/root/qwenpaw-venv/bin:\$PATH"
echo "     qwenpaw models config   ← 选 dashscope，再选模型"
echo "     （推荐 qwen3.7-plus 性价比高；或 qwen3.7-max 更强）"
echo ""
echo "  【启动后端】"
echo "     bash ~/start_qwenpaw.sh"
echo "     看到 Uvicorn running on http://127.0.0.1:8088 即成功"
echo ""
echo "  【手机 APK】"
echo "     打开「QwenPaw Mobile」自动连接 127.0.0.1:8088"
echo ""
echo "  【重复运行本脚本】可安全重跑，已装部分自动跳过"
echo "=============================================="
