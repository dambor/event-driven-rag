import os
import json
import logging
from flask import Flask, request, Response
from main import main

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger(__name__)

app = Flask(__name__)
# Forward Flask's own request logs through the same handler
app.logger.handlers = logging.root.handlers
app.logger.setLevel(logging.INFO)

@app.route('/', methods=['POST'])
def handle():
    log.info("Incoming request from %s", request.remote_addr)

    params = request.get_json(force=True, silent=True) or {}
    log.info("Payload: %s", json.dumps(params))

    result = main(params)

    # Unwrap the CE function web-action response envelope if present
    if 'statusCode' in result and 'body' in result:
        log.info("Response: status=%s body=%s", result['statusCode'], result['body'])
        return Response(
            result['body'],
            status=result['statusCode'],
            headers=result.get('headers', {}),
        )

    log.info("Response: %s", json.dumps(result))
    return Response(json.dumps(result), status=200, mimetype='application/json')

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 8080))
    log.info("Starting cos-langflow-app on port %s", port)
    app.run(host='0.0.0.0', port=port)
