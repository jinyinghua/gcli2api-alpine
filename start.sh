#!/bin/sh
# gcli2api launcher for NAT VPSes.
# `start` returns immediately: venv/pip work is done in the background and its
# progress is available temporarily at http://<VPS-IP>:${INSTALL_LOG_PORT:-7862}/logs
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"

PID_FILE="$SCRIPT_DIR/.gcli2api.pid"
BOOTSTRAP_PID_FILE="$SCRIPT_DIR/.gcli2api.bootstrap.pid"
LOG_SERVER_PID_FILE="$SCRIPT_DIR/.gcli2api.log-server.pid"
LOG_SERVER_SCRIPT="$SCRIPT_DIR/.gcli2api_log_server.py"
LOG_FILE="$SCRIPT_DIR/log.txt"
VENV_DIR="$SCRIPT_DIR/.venv"
LOG_PORT="${INSTALL_LOG_PORT:-7862}"

find_python() {
  if command -v python3 >/dev/null 2>&1; then echo python3; return 0; fi
  if command -v python >/dev/null 2>&1; then echo python; return 0; fi
  echo "未找到 python3/python；无法创建虚拟环境或提供安装日志。" >&2
  return 1
}

get_pid() { [ -f "$1" ] && cat "$1" 2>/dev/null || true; }

pid_running() {
  _pid=$(get_pid "$1")
  [ -n "${_pid:-}" ] && kill -0 "$_pid" 2>/dev/null
}

is_running() { pid_running "$PID_FILE"; }
is_bootstrapping() { pid_running "$BOOTSTRAP_PID_FILE"; }

ensure_venv() {
  if [ ! -x "$VENV_DIR/bin/python" ]; then
    echo "[$(date '+%F %T')] 创建 Python 虚拟环境..."
    PYTHON_BIN=$(find_python)
    "$PYTHON_BIN" -m venv "$VENV_DIR"
  fi
}

ensure_deps() {
  if [ "${SKIP_PIP_INSTALL:-0}" = "1" ]; then
    echo "[$(date '+%F %T')] 跳过依赖安装 (SKIP_PIP_INSTALL=1)"
    return 0
  fi
  echo "[$(date '+%F %T')] 检查/安装 Python 依赖..."
  "$VENV_DIR/bin/python" -m pip install -r "$SCRIPT_DIR/requirements.txt"
}

write_log_server() {
  cat > "$LOG_SERVER_SCRIPT" <<'PY'
# Temporary, read-only HTTP endpoint for the bootstrap log.  It deliberately
# does not serve the project directory (which contains credentials and .env).
import http.server
import os
import sys

log_file, port = sys.argv[1], int(sys.argv[2])
class LogHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split('?', 1)[0] not in ('/', '/logs', '/log.txt'):
            self.send_error(404)
            return
        try:
            with open(log_file, 'rb') as f:
                body = f.read()
        except FileNotFoundError:
            body = b'Waiting for bootstrap output...\n'
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, fmt, *args):
        pass

http.server.ThreadingHTTPServer.allow_reuse_address = True
http.server.ThreadingHTTPServer(('0.0.0.0', port), LogHandler).serve_forever()
PY
}

start_log_server() {
  if pid_running "$LOG_SERVER_PID_FILE"; then return 0; fi
  PYTHON_BIN=$(find_python)
  write_log_server
  # The log server itself writes no request log, so log.txt only contains setup/app output.
  nohup "$PYTHON_BIN" "$LOG_SERVER_SCRIPT" "$LOG_FILE" "$LOG_PORT" >/dev/null 2>&1 &
  echo "$!" > "$LOG_SERVER_PID_FILE"
  sleep 1
  if ! pid_running "$LOG_SERVER_PID_FILE"; then
    rm -f "$LOG_SERVER_PID_FILE"
    echo "无法监听临时日志端口 $LOG_PORT（可能已被占用）。" >&2
    return 1
  fi
}

stop_log_server() {
  _pid=$(get_pid "$LOG_SERVER_PID_FILE")
  if [ -n "${_pid:-}" ] && kill -0 "$_pid" 2>/dev/null; then
    kill "$_pid" 2>/dev/null || true
  fi
  rm -f "$LOG_SERVER_PID_FILE" "$LOG_SERVER_SCRIPT"
}

start_app() {
  echo "[$(date '+%F %T')] 启动 gcli2api..."
  nohup "$VENV_DIR/bin/python" "$SCRIPT_DIR/web.py" >>"$LOG_FILE" 2>&1 &
  _pid=$!
  echo "$_pid" > "$PID_FILE"
  sleep 2
  if ! kill -0 "$_pid" 2>/dev/null; then
    rm -f "$PID_FILE"
    echo "[$(date '+%F %T')] gcli2api 启动失败。" >&2
    return 1
  fi
  echo "[$(date '+%F %T')] gcli2api 已启动，PID: $_pid"
}

bootstrap() {
  # All output is redirected by start_service to LOG_FILE.
  if ensure_venv && ensure_deps && start_app; then
    echo "[$(date '+%F %T')] 初始化完成，关闭临时日志端口 $LOG_PORT。"
    stop_log_server
    rm -f "$BOOTSTRAP_PID_FILE"
    exit 0
  fi
  _rc=$?
  echo "[$(date '+%F %T')] 初始化失败（退出码 $_rc）。临时日志端口会保留，方便排错。" >&2
  rm -f "$BOOTSTRAP_PID_FILE"
  exit "$_rc"
}

start_service() {
  if is_running; then
    echo "gcli2api 已在运行，PID: $(get_pid "$PID_FILE")"
    return 0
  fi
  if is_bootstrapping; then
    echo "gcli2api 正在后台检查/安装依赖，安装日志: http://<VPS公网IP>:$LOG_PORT/logs"
    return 0
  fi

  : > "$LOG_FILE"
  if ! start_log_server; then
    echo "请更换端口后重试，例如：INSTALL_LOG_PORT=18062 sh start.sh start" >&2
    return 1
  fi

  # Keep the bootstrap independent of the invoking SSH session.
  nohup sh "$SCRIPT_DIR/start.sh" __bootstrap >>"$LOG_FILE" 2>&1 &
  echo "$!" > "$BOOTSTRAP_PID_FILE"
  echo "已在后台开始检查/安装依赖（PID: $!）。"
  echo "临时安装日志: http://<VPS公网IP>:$LOG_PORT/logs"
  echo "注意：NAT 服务商面板/防火墙必须在安装期间转发并放行该端口；gcli2api 成功启动后脚本会自动关闭它。"
}

stop_service() {
  _boot_pid=$(get_pid "$BOOTSTRAP_PID_FILE")
  if [ -n "${_boot_pid:-}" ] && kill -0 "$_boot_pid" 2>/dev/null; then
    echo "停止后台初始化，PID: $_boot_pid"
    kill "$_boot_pid" 2>/dev/null || true
  fi
  rm -f "$BOOTSTRAP_PID_FILE"
  stop_log_server

  if ! is_running; then
    echo "gcli2api 未运行"
    rm -f "$PID_FILE"
    return 0
  fi
  _pid=$(get_pid "$PID_FILE")
  echo "停止 gcli2api，PID: $_pid"
  kill "$_pid" 2>/dev/null || true
  _i=0
  while kill -0 "$_pid" 2>/dev/null; do
    _i=$((_i + 1))
    [ "$_i" -lt 10 ] || { kill -9 "$_pid" 2>/dev/null || true; break; }
    sleep 1
  done
  rm -f "$PID_FILE"
  echo "已停止"
}

status_service() {
  if is_running; then
    echo "gcli2api 正在运行，PID: $(get_pid "$PID_FILE")"
  elif is_bootstrapping; then
    echo "gcli2api 正在后台初始化，PID: $(get_pid "$BOOTSTRAP_PID_FILE")；日志: http://<VPS公网IP>:$LOG_PORT/logs"
  else
    echo "gcli2api 未运行"
    return 1
  fi
}

run_foreground() {
  ensure_venv
  ensure_deps
  exec "$VENV_DIR/bin/python" "$SCRIPT_DIR/web.py"
}

show_logs() { touch "$LOG_FILE"; tail -n 200 -f "$LOG_FILE"; }

case "${1:-start}" in
  start) start_service ;;
  stop) stop_service ;;
  restart) stop_service; start_service ;;
  status) status_service ;;
  run|foreground) run_foreground ;;
  logs) show_logs ;;
  __bootstrap) bootstrap ;;
  *) echo "用法: sh start.sh [start|stop|restart|status|run|logs]" >&2; exit 1 ;;
esac
