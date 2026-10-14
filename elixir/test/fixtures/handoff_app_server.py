#!/usr/bin/env python3
"""Owned stdio protocol fixture: actual request ids, interleaving and file-gated acknowledgements."""
import json
import pathlib
import sys
import time

mode = sys.argv[1]
context = pathlib.Path.cwd() / '.context'
context.mkdir(exist_ok=True)

def record(message):
    with (context / 'protocol.jsonl').open('a') as output:
        output.write(json.dumps(message) + '\n')

def emit(message):
    print(json.dumps(message), flush=True)

def wait(name):
    deadline = time.monotonic() + 3
    while not (context / name).exists():
        if time.monotonic() > deadline:
            raise RuntimeError('fixture gate expired: ' + name)
        time.sleep(.005)

for line in sys.stdin:
    request = json.loads(line)
    record(request)
    method = request.get('method')
    if method == 'initialize':
        emit({'id': request['id'], 'result': {}})
    elif method in ('thread/start', 'thread/resume'):
        if mode.startswith('resume'):
            if method != 'thread/resume':
                emit({'id': request['id'], 'error': {'code': -1, 'message': 'fresh fallback forbidden'}})
                continue
            result = {'thread': {'id': 'thread-owned', 'cwd': str(pathlib.Path.cwd())},
                      'cwd': str(pathlib.Path.cwd()), 'model': 'fixture-model', 'modelProvider': 'fixture-provider', 'reasoningEffort': 'high'}
            if mode == 'resume-wrong':
                result['model'] = 'different-model'
        else:
            result = {'thread': {'id': 'thread-owned'}}
        emit({'id': request['id'], 'result': result})
    elif method == 'turn/start':
        emit({'id': request['id'], 'result': {'turn': {'id': 'turn-owned'}}})
        if mode.startswith('resume'):
            emit({'method': 'item/agentMessage/delta', 'params': {'delta': 'restored fixture nonce'}})
            emit({'method': 'turn/completed', 'params': {'threadId': 'thread-owned', 'turn': {'id': 'turn-owned'}}})
    elif method == 'turn/steer':
        (context / 'steer-received').write_text('ready')
        if mode == 'disconnect':
            break
        if mode == 'silent':
            continue
        emit({'method': 'item/updated', 'params': {'threadId': 'thread-owned', 'item': {'id': 'interleaved'}}})
        emit({'id': 'approval-owned', 'method': 'item/commandExecution/requestApproval', 'params': {'threadId': 'thread-owned', 'turnId': 'turn-owned'}})
        approval = json.loads(sys.stdin.readline())
        record(approval)
        assert approval['id'] == 'approval-owned'
        wait('ack')
        if mode == 'reject':
            emit({'id': request['id'], 'error': {'code': -1, 'message': 'controlled refusal'}})
        else:
            emit({'id': request['id'], 'result': {'turnId': request['params']['expectedTurnId']}})
        wait('finish')
        emit({'method': 'turn/completed', 'params': {'threadId': 'thread-owned', 'turn': {'id': 'turn-owned'}}})
