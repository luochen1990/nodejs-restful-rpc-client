require 'coffee-mate/global'

echoPromise = (p) ->
	if not p.then? # not a promise
		instant = p
		log -> instant
	else
		p.then (r) ->
			success = if (j = prettyJson r)?.length < 80 then r else j
			log.info -> success
		.catch (e) ->
			#error = if(j = json e, 2).length < 80 then e else j
			error = if e instanceof Error then e.stack else json e
			log.error -> error

module.exports = echoPromise
