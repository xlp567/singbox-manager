"""Interactive data-only protocol creation; installed JSON never contains executable code."""
import copy
import datetime
import json
import os
import pathlib
import re
from .protocols import ADAPTERS,MODULE_DIRECTORY,MODULE_ERRORS
from .protocols.declarative import DeclarativeAdapter


def json_input(label,default,ctx):
    print(label+'：粘贴 JSON（可多行，完成后自动识别；输入 END 结束；空行使用默认）')
    for attempt in range(ctx.TRIES):
        lines=[]
        while True:
            line=input('JSON> ')
            if not lines and not line.strip():return copy.deepcopy(default)
            if line.strip()=='END':break
            lines.append(line)
            if sum(map(len,lines))>262144:raise ValueError('模板超过 256 KiB')
            try:return json.loads('\n'.join(lines))
            except ValueError:pass
        try:return json.loads('\n'.join(lines))
        except ValueError:print('JSON 格式无效，请重新粘贴。')
    raise ValueError('多次输入无效，未保存模块')


def create(ctx):
    print('新增自定义协议：使用官方配置示例和 ${参数名} 占位符，无需修改脚本。')
    print('通用地址、端口和标签由管理器填写；新协议必须得到所选 sing-box 核心支持。')
    slug=ctx.ask('模块标识（英文小写，例如 newproto）',lambda s:s if re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,24}',s) else ctx.fail('标识无效'))
    label=ctx.ask('协议中文名称',ctx.node_name)
    minimum=ctx.ask('该模板最低 sing-box 版本',lambda s:s if re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?',s) else ctx.fail('版本格式无效'),'1.14.0')
    port=ctx.ask('默认监听端口',ctx.number,7443)
    nets=[['tcp'],['udp'],['tcp','udp']][ctx.choose('监听传输',['TCP','UDP','TCP + UDP'])]
    tls=ctx.choose('是否使用共用 ACME 证书',['否，按协议模板填写','是，管理器填写证书和验证参数'])==1
    fields=json_input('参数表单，如 [{"key":"password","label":"密码","type":"password"}]',[],ctx)
    server=json_input('服务端入站模板（必填 type；不填 tag/listen/listen_port）',{},ctx)
    client=json_input('客户端出站模板（必填 type；不填 tag/server/server_port）',{},ctx)
    uri=ctx.prompt('导入 URI 模板（可留空，使用客户端 JSON）','')
    return {'format':1,'kind':'custom-'+slug,'label':label,'module_version':'1.0.0','minimum_runtime':minimum,
            'default_port':port,'networks':nets,'tls':tls,'server_tags':[],
            'fields':fields,'server_template':server,'client_template':client,'uri_template':uri}


def install(data,binary,ctx):
    adapter=DeclarativeAdapter(data);root=pathlib.Path(MODULE_DIRECTORY)
    target=root/(adapter.kind+'.json')
    if root.is_symlink() or target.exists() or target.is_symlink():raise ValueError('模块已存在或路径异常；不会覆盖已使用的模板')
    # A future-core template can be staged; compatible templates must pass official checks now.
    ADAPTERS[adapter.kind]=adapter
    try:
        m=ctx.new_model();m['acme']={'domain':'module.example.com','email':'module@example.com','provider':'letsencrypt','challenge':'http','key_type':'p256'}
        m['nodes']=[adapter.sample(ctx,binary)]
        compatibility=ctx.PROTOCOL_ENGINE.compatibility(m,binary,ctx.validation)
        if compatibility['compatible']:
            report=ctx.PROTOCOL_ENGINE.module_tests(binary,ctx,adapter.kind)
            if not report['passed']:raise ValueError('当前官方核心不接受此服务端 / 客户端模板，未安装模块；请核对官方示例')
            status='已通过当前核心配置检查'
        else:status='已保存为待升级核心验证的模块；不兼容时不能部署节点'
        root.mkdir(parents=True,exist_ok=True);os.chmod(root,0o700);ctx.save(target,data)
        print('自定义协议模块已保存：'+adapter.kind+' | '+status)
        print('现在可以用菜单 3 添加该协议节点；菜单 28 可继续管理模块。')
    except Exception:
        ADAPTERS.pop(adapter.kind,None)
        raise


def remove(kind,conf,state,ctx):
    if not re.fullmatch(r'custom-[a-z0-9][a-z0-9_-]{0,24}',kind):raise ValueError('只能移除自定义模块，内置协议保留')
    for file in [pathlib.Path(conf)/'manager.json',pathlib.Path(state)/'draft.json']:
        if not file.exists():continue
        data=ctx.load(file);m=data.get('model',data)
        if any(n.get('kind')==kind for n in m.get('nodes',[])):raise ValueError('线上节点或未提交草稿仍引用此模块，请先处理节点 / 草稿')
    path=pathlib.Path(MODULE_DIRECTORY)/(kind+'.json')
    if path.is_symlink() or not path.is_file():raise ValueError('模块文件不存在或路径异常')
    if ctx.prompt('将自定义模块归档移除，输入 DELETE 确认')!='DELETE':raise ValueError('已取消模块移除')
    archive=pathlib.Path(state)/'archived-protocols';archive.mkdir(parents=True,exist_ok=True);os.chmod(archive,0o700)
    dest=archive/(kind+'-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')+'.json')
    os.replace(path,dest);os.chmod(dest,0o600);ctx.sync_directory(path.parent);ctx.sync_directory(archive)
    print('模块已归档移除；未修改线上配置。')


def command(args,ctx):
    operation=args[0]
    if operation=='create':return install(create(ctx),args[1],ctx)
    if operation=='import':
        path=pathlib.Path(args[1])
        if path.is_symlink() or path.stat().st_size>262144:raise ValueError('模板文件路径或大小异常')
        return install(ctx.load(path),args[2],ctx)
    if operation=='delete':return remove(args[1],args[2],args[3],ctx)
    if operation=='errors':
        for kind,reason in MODULE_ERRORS.items():print(kind+': '+reason)
        return
    raise ValueError('协议模块管理操作无效')
