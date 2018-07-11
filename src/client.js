const url = require('url');
const http = require('http');
const https = require('https');
const defineError = require('node-define-error');

const HttpRequestError = defineError('HttpRequestError', ['protocol', 'host', 'port']);
const HttpRequestAborted = defineError('HttpRequestAborted', ['msg']);
const HttpResponseError = defineError('HttpResponseError', ['code', 'body']);

// format :: String -> Map String (forall v, Show v => v) -> String
const format = form => vars => form.replace(/\{(\w+)\}/g, (m, i) => vars[i] != null ? vars[i] : m);

// type HttpServiceEntry = { protocol :: String, host :: String, port :: Int, prefix :: String }
// parseEntry :: EntryDesc -> (() => Promise HttpServiceEntry)
// type EntryDesc = String
const parseEntry = entry => {
	const r = url.parse(entry);
	const port = parseInt(r.port != null ? r.port : (r.protocol === 'https:' ? 443 : 80));
	return () => Promise.resolve({protocol: r.protocol.slice(0, -1), host: r.hostname, port, prefix: r.pathname});
};

// keepAliveAgents :: Options -> (Map ProtocolName HttpAgent)
const keepAliveAgents = (() => {
	const Agent = require('agentkeepalive');
	return opts => ({http: new Agent(opts), https: new Agent.HttpsAgent(opts)});
})();

// type HttpRequest = { entry :: HttpServiceEntry, payload :: HttpRequestPayload, abortEvent :: Event }
// type HttpRequestPayload = { method, path, search, headers, body }
// type HttpResponse = { headers :: Map String String, code :: Int, body :: String }
// sendRequest :: (HttpRequest, Map ProtocolName HttpAgent) -> PromiseIO HttpResponse
const sendRequest = ({entry, payload, abortEvent}, agents = {}) => {
	const {protocol, host, port, prefix} = entry;
	const {method, path, search, headers, body} = payload;
	const [client, agent] = [{http, https}[protocol], agents[protocol]];
	const httpQry = {host, port, method, path: (prefix + path + (search != null ? search : '')), headers, agent};

	return new Promise((resolve, reject) => {
		const responsed = new Promise((resolveResponsed, rejectResponsed) => {
			const request = client.request(httpQry, response => {
				response.setEncoding('utf8');
				let responseData = '';
				response.on('data', chunk => {
					responseData += chunk;
				});
				response.on('end', () => {
					resolveResponsed();
					resolve({
						headers: response.headers,
						code: response.statusCode,
						body: responseData
					});
			});
		});
			request.on('error', err => {
				reject(new HttpRequestError({protocol, host, port}, err));
			});
			if (body != null) { request.write(body); }
			request.end();
		});

		if (abortEvent != null) {
			Promise.race([responsed.then(r => [0, r]), abortEvent.then(r => [1, r])]).then(([flag, msg]) => {
				if (flag === 1) {
					request.abort(); //TODO: more consideration
					reject(new HttpRequestAborted({msg}));
				}
			});
		}
	});
};

// simpleJsonAdapter :: HttpAdapter
const simpleJsonAdapter = {
	input: ({apiName, method, pathPattern}) => {
		return (input, context) => {
			let body, headers, search;
			if (['POST', 'PUT', 'PATCH'].includes(method)) {
				headers = {
					'Content-Type': 'application/json; charset=utf-8',
					'Content-Length': Buffer.byteLength(body, ['utf-8']) //TODO: browser compatibility
				};
				body = json((input != null ? input : null));
				search = null;
			} else {
				headers = {};
				body = null;
				search = `?${uri_encoder(json)(input)}`;
			}
			const path = format(pathPattern)(input);
			return {method, path, search, headers, body};
		};
	},
	output: ({apiName, method, pathPattern}) => {
		return (result, context) => {
			return result.then(({headers, code, body}) => {
				if (200 <= code && code < 300) {
					return JSON.parse(body);
				} else {
					throw new HttpResponseError({code, body});
				}
			});
		};
	}
};

// type ClientConfig = {entry :: EntryDesc, api :: ApiConfig, adapter :: HttpAdapter, wrapper :: ProcWrapper, agents: Map ProtocolName HttpAgent}
// type ApiConfig = Map ApiName HttpQueryPattern
// type ApiName = String
// type HttpQueryPattern = String
// type HttpAdapter = {input :: InputAdapter, output :: OutputAdapter}
// type InputAdapter = ApiInfo -> (input, ctxt) -> HttpRequestPayload --??
// type OutputAdapter = ApiInfo -> (PromiseIO HttpResponse, ctxt) -> PromiseIO output --??
// type ProcWrapper = ApiInfo -> Procedure ... -> Procedure ...
// type Procedure i is o osf = i -> STrans PromiseIO o is osf
// buildClient :: ClientConfig -> Map ApiName Procedure
const buildClient = ({entry, api, adapter, wrapper, agents}) => {
	const {input: inputAdapter, output: outputAdapter} = adapter != null ? adapter : simpleJsonAdapter;
	if (wrapper == null) { wrapper = () => x => x; }
	if (agents == null) { agents = keepAliveAgents({}); }
	const getEntry = parseEntry(entry);

	return fromList(map(([apiName, queryPattern]) => {
		const [_, method, pathPattern] = queryPattern.match(/^([A-Za-z]+)\s+([^ ]+)/);
		const apiInfo = {apiName, method: method.toUpperCase(), pathPattern};
		const inputAdpt = inputAdapter(apiInfo);
		const outputAdpt = outputAdapter(apiInfo);
		const wrap = wrapper(apiInfo);

		const proc = (input, context) => {
			if (context == null) { context = {}; }
			const payl = inputAdpt(input, context);
			const res = getEntry().then(entr => sendRequest({entry: entr, payload: payl, abortEvent: context.abortEvent}, agents));
			return outputAdpt(res, context);
		};
		return [apiName, wrap(proc)];
	})(enumerate(api))
	);
};

module.exports = {buildClient, sendRequest, simpleJsonAdapter, keepAliveAgents};

/* !pragma coverage-skip-next */
if (module.parent === null) { //
	const echo = require('../test/echoPromise');

	const client = buildClient({
		entry: 'http://127.0.0.1:1024/a',
		api: {
			'plus': 'GET /plus'
		}
	});
	echo(client.plus({a: 1, b: 2}));
}

