# 不安装命令、不迁移参数、不请求网络、不运行内核配置检查。
do_doctor() {
    if ! command -v python3 >/dev/null 2>&1; then
        warn "统一诊断未完成：缺少 python3，未安装任何依赖"
        return 2
    fi
    engine_python doctor
}

do_doctor_menu() { do_doctor || true; press_enter; }
