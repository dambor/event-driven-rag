import os
import json
from flask import Flask, request, Response
from main import main

app = Flask(__name__)

@app.route('/', methods=['POST'])
def handle():
    params = request.get_json(force=True, silent=True) or {}
    result = main(params)
    # Unwrap the CE function web-action response envelope if present
    if 'statusCode' in result and 'body' in result:
        return Response(
            result['body'],
            status=result['statusCode'],
            headers=result.get('headers', {}),
        )
    return Response(json.dumps(result), status=200, mimetype='application/json')

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 8080))
    app.run(host='0.0.0.0', port=port)
