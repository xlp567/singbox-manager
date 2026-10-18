"""Lazy boundary: recovery/storage/audit do not import any protocol module."""
import json
import subprocess
import sys
from .core import storage,audit
from .runtime import Runtime


def main():
    command=sys.argv[1];args=sys.argv[2:]
    if command=='manager-update':
        from .core.self_update import command as update_command
        return update_command(args)
    commands={'backup-seal':storage.backup_seal,'backup-verify':storage.backup_verify,
              'backup-complete':storage.backup_complete,'pending-write':storage.pending_write,
              'pending-clear':storage.pending_clear,'runtime-copy-libs':storage.runtime_copy_libraries,
              'audit-append':audit.append}
    if command in commands:return commands[command](*args)
    if command=='runtime-id':print(storage.runtime_identity(*args));return
    if command=='draft-summary':
        report=storage.draft_summary(args[0])
        if '--json' in args:print(json.dumps(report,ensure_ascii=False))
        elif not report['exists']:print('没有未提交草稿。')
        elif report['corrupt']:print('草稿结构无法读取，可以归档清理；不会改动线上节点。')
        else:
            print(f"未提交草稿：{report['node_count']} 个节点（草稿可能包含线上节点的编辑副本）")
            for n in report['nodes']:print(f"  {n['name']} | {n['protocol']} | {n['port']} | {'启用' if n['enabled'] else '停用'}")
        return
    if command=='draft-fingerprint':
        report=storage.draft_summary(args[0])
        if not report['exists']:raise ValueError('没有未提交草稿')
        print(report['sha256']);return
    if command=='draft-discard':print(storage.draft_discard(*args));return
    if command=='draft-purge':storage.draft_purge(*args);return
    if command=='draft-archive-plan':
        report=storage.draft_archive_inventory(args[0]);storage.save(args[1],report)
        print(f"将永久删除 {report['count']} 份已归档草稿，共 {report['bytes']} 字节；目录：{report['directory']}")
        for file in report['files']:print('  '+file['name'])
        return
    if command=='draft-archives-purge':print(storage.draft_archives_purge(*args));return
    if command=='paths':
        from .core.locations import inventory
        report=inventory(*args[:9])
        if '--json' in args[9:]:print(json.dumps(report,ensure_ascii=False))
        else:
            for row in report['paths']:
                print(row['label']+'：'+row['path']+(' [尚未生成]' if not row['exists'] else ''))
                if 'target' in row:print('  实际位置：'+row['target'])
            print('临时目录：'+report['temporary_directories'])
            print('运行日志：'+report['service_log_command']);print('空间清理：'+report['cleanup'])
        return
    if command=='audit-verify':
        report=audit.verify(args[0])
        if '--json' in args:print(json.dumps(report))
        else:print(f"审计链：通过 | {report['entries']} 条记录 | {report['last_hash']}")
        return
    if command=='runtime-info':
        info=Runtime(args[0]).info()
        if '--json' in args:print(json.dumps(info))
        else:print('sing-box '+info['version']+' | 构建能力：'+', '.join(info['tags']))
        return
    from .engine import main as protocol_command
    return protocol_command()


def run():
    try:main()
    except (ValueError,KeyError,TypeError,AttributeError,IndexError,OSError,EOFError,subprocess.SubprocessError) as error:
        print('错误：'+str(error),file=sys.stderr);sys.exit(1)
    except KeyboardInterrupt:
        print('\n已取消，未提交的编辑已丢弃。',file=sys.stderr);sys.exit(130)
