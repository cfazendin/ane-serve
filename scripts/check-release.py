#!/usr/bin/env python3
"""Run bounded live checks against an isolated release server; save raw responses.

Requires a prepared trail-guide.mp4 from examples/video-scan/make-demo.swift.
The runner starts and terminates only its own child server, on a free localhost port.
"""
import argparse
import base64
import datetime
import hashlib
import http.client
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--binary', default='.build/release/ane-serve')
parser.add_argument('--video', default='/private/tmp/ane-serve-release-demo/trail-guide.mp4')
parser.add_argument('--output', default='.build/release-check/results')
args = parser.parse_args()
binary = str(Path(args.binary).resolve())
video = Path(args.video).resolve()
output = Path(args.output).resolve()
output.mkdir(parents=True, exist_ok=True)
key = secrets.token_hex(24)
env = os.environ.copy()
for name in ('HOST', 'PORT', 'ANE_API_KEY'):
    env.pop(name, None)
checks = []

def save(name, value):
    (output / name).write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')

def record(name):
    checks.append(name)
    print('PASS:', name, flush=True)

with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
log = (output / 'server.log').open('w')
server = subprocess.Popen([binary, '--port', str(port), '--api-key', key, '--media-root', str(video.parent)],
                          env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)

def request(path, payload=None, authenticated=True, extra_headers=None):
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=180)
    headers = {'Content-Type': 'application/json'}
    if authenticated:
        headers['Authorization'] = 'Bearer ' + key
    headers.update(extra_headers or {})
    body = json.dumps(payload).encode() if payload is not None else None
    connection.request('POST' if payload is not None else 'GET', path, body, headers)
    response = connection.getresponse()
    data = json.loads(response.read())
    status = response.status
    connection.close()
    return status, data

def unauthenticated_upload_status():
    """Declare a 50 MB body without a key; the server must answer before any of it is sent."""
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
    connection.putrequest('POST', '/v1/video/scan')
    connection.putheader('Content-Type', 'application/json')
    connection.putheader('Content-Length', str(50 * 1024 * 1024))
    connection.endheaders()
    status = connection.getresponse().status
    connection.close()
    return status

def stream(name, payload):
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=120)
    connection.request('POST', '/v1/chat/completions', json.dumps(payload).encode(),
                       {'Content-Type': 'application/json', 'Authorization': 'Bearer ' + key})
    response = connection.getresponse()
    assert response.status == 200, (response.status, response.read().decode())
    assert response.getheader('Content-Type').startswith('text/event-stream')
    frames = []
    timings = []
    start = time.monotonic()
    done = False
    while True:
        line = response.readline()
        if not line:
            break
        if not line.startswith(b'data: '):
            continue
        data = line[6:].strip()
        timings.append(round(time.monotonic() - start, 6))
        if data == b'[DONE]':
            done = True
            break
        frame = json.loads(data)
        assert 'error' not in frame, frame
        frames.append(frame)
    connection.close()
    assert done, 'Missing [DONE]'
    assert frames[0]['choices'][0]['delta']['role'] == 'assistant'
    choices = [frame for frame in frames if frame['choices']]
    assert choices[-1]['choices'][0]['finish_reason'] in ('stop', 'length')
    assert 'ane_telemetry' in choices[-1]
    usage = [frame for frame in frames if not frame['choices']]
    assert len(usage) == 1 and usage[0]['usage']['completion_tokens'] > 0
    content = ''.join(frame['choices'][0]['delta'].get('content', '') for frame in choices)
    assert content.strip(), 'Empty streamed content'
    save(name + '.json', {'content': content, 'frames': frames, 'event_times_seconds': timings, 'done': done})
    return content

try:
    for _ in range(100):
        if server.poll() is not None:
            raise RuntimeError('Server exited: ' + (output / 'server.log').read_text())
        try:
            status, health = request('/v1/health')
            if status == 200:
                break
        except (OSError, http.client.HTTPException):
            time.sleep(0.1)
    else:
        raise RuntimeError('Server did not become ready')
    save('health.json', health)
    assert health['readiness']['language_model']['ready'], health['readiness']
    assert health['readiness']['ffmpeg'] and health['readiness']['ffprobe']
    record('health and model/tool readiness')

    denied = subprocess.run([binary, '--host', '0.0.0.0', '--port', str(port)], env=env, capture_output=True, text=True, timeout=15)
    assert denied.returncode != 0 and 'require an API key' in denied.stderr
    record('LAN binding without a key is rejected')
    setup = subprocess.run([binary, '--prepare-speech'], env=env, capture_output=True, text=True, timeout=120)
    assert setup.returncode == 0, setup.stderr
    status, health = request('/v1/health')
    save('health.json', health)
    assert health['readiness']['speech']['ready'], health['readiness']
    record('speech preparation command and ready state')

    status, denied = request('/v1/health', authenticated=False)
    assert status == 401 and set(denied['error']) == {'message', 'type', 'param', 'code'}
    assert unauthenticated_upload_status() == 401
    record('API authentication and error envelope')
    for field, value in [('max_duration_sec', 1e100), ('frame_interval_sec', 0), ('scene_threshold', -1), ('max_vlm_scenes', 33)]:
        status, error = request('/v1/video/scan', {field: value})
        assert status == 400 and error['error']['param'] == field, (status, error)
    status, error = request('/v1/vision/analyze', {'image_base64': '!!!'})
    assert status == 400 and error['error']['code'] == 'invalid_base64', error
    status, error = request('/v1/video/scan', {'video_base64': base64.b64encode(b'not a video').decode()})
    assert status == 400 and error['error']['code'] == 'invalid_media', error
    status, error = request('/v1/video/scan', {'video_path': str(Path(__file__).resolve())})
    assert status == 400 and error['error']['code'] == 'invalid_path', error
    status, error = request('/v1/video/scan', {'video_base64': base64.b64encode(b'#EXTM3U\n').decode(), 'format': 'm3u8'})
    assert status == 400 and error['error']['param'] == 'format', error
    record('invalid video options, invalid images, and invalid media return errors')

    recall = {'model': 'apple-foundation-model-ane', 'temperature': 0, 'max_tokens': 16,
              'messages': [{'role': 'system', 'content': 'Answer with the requested color name only.'},
                           {'role': 'user', 'content': 'Remember the color blue.'},
                           {'role': 'assistant', 'content': 'I will remember blue.'},
                           {'role': 'user', 'content': 'Which color did I ask you to remember?'}]}
    status, result = request('/v1/chat/completions', recall)
    save('conversation-recall.json', result)
    assert status == 200, result
    assert 'blue' in result['choices'][0]['message']['content'].lower(), result
    assert 0 < result['usage']['completion_tokens'] <= 16, result['usage']
    record('native conversation recall, greedy sampling, and token limit')

    stream('chat-stream', {'prompt': 'Write one sentence about a river trail.', 'temperature': 0, 'max_tokens': 32,
                           'stream': True, 'stream_options': {'include_usage': True}})
    record('live SSE chat, finish metadata, token usage, and DONE')

    image = video.parent / 'scene1.png'
    data_url = 'data:image/png;base64,' + base64.b64encode(image.read_bytes()).decode()
    status, result = request('/v1/vision/analyze', {'image_base64': data_url, 'detail': 'short', 'temperature': 0, 'max_tokens': 96})
    save('image-analysis.json', result)
    assert status == 200 and result['vlm_description'].strip(), result
    assert 'RIVER' in result['ocr_full_text'].upper() and 'TRAIL' in result['ocr_full_text'].upper(), result
    record('uploaded image OCR, caption, and telemetry')
    caption = stream('image-chat-stream', {'messages': [{'role': 'user', 'content': [
        {'type': 'text', 'text': 'Read only the large title in this image.'},
        {'type': 'image_url', 'image_url': {'url': data_url}}]}], 'temperature': 0, 'max_tokens': 24,
        'stream': True, 'stream_options': {'include_usage': True}})
    assert 'river' in caption.lower() and 'trail' in caption.lower(), caption
    record('live image chat stream')

    scan_request = {'video_path': str(video), 'max_duration_sec': 180, 'frame_interval_sec': 1,
                    'scene_threshold': 0.2, 'max_vlm_scenes': 3}
    save('video-request.json', scan_request)
    status, scan = request('/v1/video/scan', scan_request)
    save('video-response.json', scan)
    assert status == 200, scan
    assert scan['status'] == 'complete' and not scan['warnings'], scan
    assert abs(scan['analyzedDurationSec'] - 12) < 0.1 and scan['requestedDurationSec'] == 180, scan
    assert abs(scan['realtimeSpeedupFactor'] - scan['analyzedDurationSec'] / scan['totalProcessingTimeSec']) < 1e-8
    assert 'trail' in scan['fullTranscriptText'].lower(), scan
    assert scan['transcriptSegments'] and any(segment['endTimeSec'] > segment['startTimeSec'] for segment in scan['transcriptSegments'])
    assert scan['scenes'] and all(scene['captionStatus'] == 'complete' for scene in scan['scenes'])
    assert scan['executiveSummary'].strip()
    record('complete real video scan, timestamped speech, captions, summary, and actual duration')

    status, upload = request('/v1/video/scan', {'video_base64': base64.b64encode(video.read_bytes()).decode(),
        'format': 'mp4', 'max_duration_sec': 3, 'max_vlm_scenes': 0})
    save('video-upload.json', upload)
    assert status == 200 and upload['status'] == 'complete', upload
    assert abs(upload['analyzedDurationSec'] - 3) < 0.01
    assert not Path(upload['videoPath']).exists(), 'Temporary upload was not removed'
    record('video upload, duration clipping, and temporary-file cleanup')

    save('provenance.json', {'captured_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
         'hardware': health['hardware'], 'video_sha256': hashlib.sha256(video.read_bytes()).hexdigest(),
         'checks': checks, 'video_request': scan_request, 'server_started_and_stopped_by_runner': True})
    print('All', len(checks), 'live checks passed. Captured responses:', output, flush=True)
finally:
    server.terminate()
    try:
        server.wait(timeout=10)
    except subprocess.TimeoutExpired:
        server.kill()
        server.wait()
    log.close()
