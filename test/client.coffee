{buildClient, sendRequest, simpleJsonAdapter, keepAliveAgents} = require '../src/client.coffee'

### !pragma coverage-skip-next ###
if module.parent is null #
	echo = require './echoPromise'

	client = buildClient {
		entry: 'http://127.0.0.1:1024/a'
		api: {
			'plus': 'GET /plus'
		}
	}
	echo client.plus({a: 1, b: 2})

