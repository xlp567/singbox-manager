def map_public_origin(config,port):
    """TEST ONLY: map a public policy decision to an isolated loopback origin.

    Keep all deny/resolve rules before this mapping. Production configuration
    never uses override_address; the companion egress suite tests the denials.
    """
    config['dns']={'servers':[{'type':'hosts','tag':'system','predefined':{
        'public.example':['.'.join(map(str,[8,8,4,4]))]}}]}
    rule=config['route']['rules'][-2]
    assert rule['action']=='route' and rule['ip_cidr']==['0.0.0.0/0','::/0']
    rule.update(override_address='127.0.0.1',override_port=port)

