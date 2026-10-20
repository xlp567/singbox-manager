"""Read-only inventory of manager-owned locations. Never reads file contents."""
import pathlib


def inventory(conf,state,runtime,drop,exports,data,shortcut,script,unit):
    c=pathlib.Path(conf);s=pathlib.Path(state);r=pathlib.Path(runtime);d=pathlib.Path(data)
    paths=[('当前管理脚本',script),('ROOT 目录管理脚本','/root/singbox-manager.sh'),('快捷命令',shortcut),('官方运行程序',r/'current/sing-box'),
           ('当前运行版本目录',r/'current'),('所有已下载运行版本',r/'releases'),
           ('服务端实际配置',c/'config.json'),('节点管理数据（含凭据）',c/'manager.json'),
           ('配置目录',c),('未提交草稿（含凭据）',s/'draft.json'),
           ('已放弃草稿归档',s/'discarded-drafts'),('完整备份',s/'backups'),
           ('客户端导出资料（含凭据）',exports),('自定义 / 自动协议模块',s/'protocols'),
           ('已移除协议模块归档',s/'archived-protocols'),('事务恢复标记',s/'pending'),
           ('审计日志',s/'audit.jsonl'),('审计追加与轮转锁',s/'audit.jsonl.lock'),
           ('隔离审计文件及配套封存段目录',s),('BBR 原设置 / 待恢复记录',s/'bbr-original.conf'),
           ('管理员确认的公网地址',s/'public-addresses.json'),('备份运行文件对象',s/'runtime-objects'),
           ('版本查询状态',s/'latest-query.json'),('上次稳定版查询提示（仅用于显示）',s/'latest-stable'),
           ('管理锁',s/'manager.lock'),('状态目录',s),('运行数据',d),
           ('管理脚本历史备份',s/'manager-backups'),('脚本升级恢复标记',s/'manager-update-pending.json'),
           ('GitHub 升级源',s/'update-source.json'),('GitHub 私有仓库只读令牌',s/'github-token'),
           ('GitHub 首次安装记录',s/'install-origin.json'),
           ('ACME 证书与账户数据',d/'acme'),('systemd 管理器覆盖文件',drop)]
    if unit:paths.append(('systemd 主服务文件',unit))
    rows=[]
    for name,value in paths:
        p=pathlib.Path(value);row={'label':name,'path':str(p),'exists':p.exists()}
        if p.is_symlink() or p.exists() and p.resolve()!=p.absolute():row['target']=str(p.resolve())
        rows.append(row)
    return {'paths':rows,'service_log_command':'journalctl -u sing-box -n 100 --no-pager',
            'cleanup':'菜单 22：永久删除当前草稿 / 清空已归档草稿；菜单 24：清理旧备份和旧运行版本',
            'temporary_directories':str(s/'tmp.*')+'（管理脚本退出时清理；中断残留在下次取得管理锁后清理）'}
