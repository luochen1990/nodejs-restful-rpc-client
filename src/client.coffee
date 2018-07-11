url = require 'url'
http = require 'http'
https = require 'https'
defineError = require 'node-define-error'

HttpRequestError = defineError('HttpRequestError', ['protocol', 'host', 'port'])
HttpRequestAborted = defineError('HttpRequestAborted', ['msg'])
HttpResponseError = defineError('HttpResponseError', ['code', 'body'])

# format :: String -> Map String (forall v, Show v => v) -> String
format = (form) => (vars) => form.replace /\{(\w+)\}/g, (m, i) => vars[i] ? m

# type HttpServiceEntry = { protocol :: String, host :: String, port :: Int, prefix :: String }
# parseEntry :: EntryDesc -> (() => Promise HttpServiceEntry)
# type EntryDesc = String
parseEntry = (entry) =>
	r = url.parse(entry)
	port = parseInt(r.port ? (if r.protocol is 'https:' then 443 else 80))
	return () => Promise.resolve({protocol: r.protocol[...-1], host: r.hostname, port, prefix: r.pathname})

# keepAliveAgents :: Options -> (Map ProtocolName HttpAgent)
keepAliveAgents = do =>
	Agent = require('agentkeepalive')
	return (opts) => {http: new Agent(opts), https: new Agent.HttpsAgent(opts)}

# type HttpRequest = { entry :: HttpServiceEntry, payload :: HttpRequestPayload, abortEvent :: Event }
# type HttpRequestPayload = { method, path, search, headers, body }
# type HttpResponse = { headers :: Map String String, code :: Int, body :: String }
# sendRequest :: (HttpRequest, Map ProtocolName HttpAgent) -> PromiseIO HttpResponse
sendRequest = ({entry, payload, abortEvent}, agents = {}) =>
	{protocol, host, port, prefix} = entry
	{method, path, search, headers, body} = payload
	[client, agent] = [{http, https}[protocol], agents[protocol]]
	httpQry = {host, port, method, path: (prefix + path + (search ? '')), headers, agent}

	return new Promise (resolve, reject) =>
		responsed = new Promise (resolveResponsed, rejectResponsed) =>
			request = client.request httpQry, (response) =>
				response.setEncoding 'utf8'
				responseData = ''
				response.on 'data', (chunk) =>
					responseData += chunk
				response.on 'end', =>
					resolveResponsed()
					resolve {
						headers: response.headers
						code: response.statusCode
						body: responseData
					}
			request.on 'error', (err) =>
				reject(new HttpRequestError({protocol, host, port}, err))
			request.write body if body?
			request.end()

		if abortEvent?
			Promise.race([responsed.then((r) => [0, r]), abortEvent.then((r) => [1, r])]).then ([flag, msg]) =>
				if flag is 1
					request.abort() #TODO: more consideration
					reject(new HttpRequestAborted({msg}))

# simpleJsonAdapter :: HttpAdapter
simpleJsonAdapter = {
	input: ({apiName, method, pathPattern}) =>
		return (input, context) =>
			if method in ['POST', 'PUT', 'PATCH']
				headers = {
					'Content-Type': 'application/json; charset=utf-8'
					'Content-Length': Buffer.byteLength(body, ['utf-8']) #TODO: browser compatibility
				}
				body = json (input ? null)
				search = null
			else
				headers = {}
				body = null
				search = '?' + uri_encoder(json)(input)
			path = format(pathPattern)(input)
			return {method, path, search, headers, body}
	output: ({apiName, method, pathPattern}) =>
		return (result, context) =>
			return result.then ({headers, code, body}) =>
				if 200 <= code < 300
					return JSON.parse body
				else
					throw new HttpResponseError({code, body})
}

# type ClientConfig = {entry :: EntryDesc, api :: ApiConfig, adapter :: HttpAdapter, wrapper :: ProcWrapper, agents: Map ProtocolName HttpAgent}
# type ApiConfig = Map ApiName HttpQueryPattern
# type ApiName = String
# type HttpQueryPattern = String
# type HttpAdapter = {input :: InputAdapter, output :: OutputAdapter}
# type InputAdapter = ApiInfo -> (input, ctxt) -> HttpRequestPayload --??
# type OutputAdapter = ApiInfo -> (PromiseIO HttpResponse, ctxt) -> PromiseIO output --??
# type ProcWrapper = ApiInfo -> Procedure ... -> Procedure ...
# type Procedure i is o osf = i -> STrans PromiseIO o is osf
# buildClient :: ClientConfig -> Map ApiName Procedure
buildClient = ({entry, api, adapter, wrapper, agents}) =>
	{input: inputAdapter, output: outputAdapter} = adapter ? simpleJsonAdapter
	wrapper ?= () => (x) => x
	agents ?= keepAliveAgents({})
	getEntry = parseEntry(entry)

	return fromList map(([apiName, queryPattern]) =>
		[_, method, pathPattern] = queryPattern.match(/^([A-Za-z]+)\s+([^ ]+)/)
		apiInfo = {apiName, method: method.toUpperCase(), pathPattern}
		inputAdpt = inputAdapter apiInfo
		outputAdpt = outputAdapter apiInfo
		wrap = wrapper apiInfo

		proc = (input, context) =>
			context ?= {}
			payl = inputAdpt(input, context)
			res = getEntry().then (entr) => sendRequest({entry: entr, payload: payl, abortEvent: context.abortEvent}, agents)
			return outputAdpt(res, context)
		return [apiName, wrap(proc)]
	) enumerate(api)

module.exports = {buildClient, sendRequest, simpleJsonAdapter, keepAliveAgents}

### !pragma coverage-skip-next ###
if module.parent is null #
	echo = require '../test/echoPromise'

	client = buildClient {
		entry: 'http://127.0.0.1:1024/a'
		api: {
			'plus': 'GET /plus'
		}
	}
	echo client.plus({a: 1, b: 2})

