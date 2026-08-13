#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"

PID_FILE="$SCRIPT_DIR/.gcli2api.pid"
LOG_FILE="$SCRIPT_DIR/log.txt"
VENV_DIR="$SCRIPT_DIR/.venv"

find_python() {
  if command -v python3 >/dev/null 2>&1; then
    echo python3
    return 0
  fi
  if command -v python >/dev/null 2>&1; then
    echo python
    return 0
  fi
  echo "未找到 python3/python" >&2
  exit 1
}

ensure_venv() {
  if [ ! -d "$VENV_DIR" ]; then
    echo "创建虚拟环境..."
    PYTHON_BIN=$(find_python)
    "$PYTHON_BIN" -m venv "$VENV_DIR"
  fi
  . "$VENV_DIR/bin/activate"
}

ensure_deps() {
  if [ "${SKIP_PIP_INSTALL:-0}" = "1" ]; then
    echo "跳过依赖安装 (SKIP_PIP_INSTALL=1)"
    return 0
  fi
  echo "检查/安装依赖..."
  python -m pip install -r requirements.txt
}

get_pid() {
  if [ -f "$PID_FILE" ]; then
    cat "$PID_FILE" 2>/dev/null || true
  fi
}

is_running() {
  PID=$(get_pid)
  if [ -n "${PID:-}" ] && kill -0 "$PID" 2>/dev/null; then
    return 0
  fi
  return 1
}

start_service() {
  if is_running; then
    echo "gcli2api 已在运行，PID: $(get_pid)"
    return 0
  fi

  ensure_venv
  ensure_deps

  echo "启动 gcli2api..."
  nohup sh -c '. "'$VENV_DIR'/bin/activate" && exec python web.py' >>"$LOG_FILE" 2>&1 &
  PID=$!
  echo "$PID" > "$PID_FILE"
  sleep 2

  if kill -0 "$PID" 2>/dev/null; then
    echo "启动成功，PID: $PID"
    echo "日志文件: $LOG_FILE"
  else
    echo "启动失败，请查看日志: $LOG_FILE" >&2
    exit 1
  fi
}

stop_service() {
  if ! is_running; then
    echo "gcli2api 未运行"
    rm -f "$PID_FILE"
    return 0
  fi

  PID=$(get_pid)
  echo "停止 gcli2api，PID: $PID"
  kill "$PID" 2>/dev/null || true

  i=0
  while kill -0 "$PID" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge 10 ]; then
      echo "进程未正常退出，强制结束..."
      kill -9 "$PID" 2>/dev/null || true
      break
    fi
    sleep 1
  done

  rm -f "$PID_FILE"
  echo "已停止"
}

status_service() {
  if is_running; then
    echo "gcli2api 正在运行，PID: $(get_pid)"
  else
    echo "gcli2api 未运行"
    return 1
  fi
}

run_foreground() {
  ensure_venv
  ensure_deps
  exec python web.py
}

show_logs() {
  touch "$LOG_FILE"
  tail -n 200 -f "$LOG_FILE"
}

case "${1:-start}" in
  start)
    start_service
    ;;
  stop)
    stop_service
    ;;
  restart)
    stop_service
    start_service
    ;;
  status)
    status_service
    ;;
  run|foreground)
    run_foreground
    ;;
  logs)
    show_logs
    ;;
  *)
    echo "用法: sh start.sh [start|stop|restart|status|run|logs]" >&2
    exit 1
    ;;
esac
