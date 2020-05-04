--DROP EVENT SESSION [ErrorSession] ON SERVER

--Created 2/1/2017 Chuck Lathrope
--This creates a small ring buffer (memory allocated for events) for watching for errors that are common for application issues
--Check for existance
IF NOT EXISTS (
	SELECT 1
	FROM  sys.server_event_sessions 
	WHERE name = 'ErrorSession' 
)
BEGIN
	CREATE EVENT SESSION [ErrorSession] ON SERVER 
	ADD EVENT sqlserver.error_reported(
		ACTION(package0.collect_system_time,sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.database_id,sqlserver.sql_text,sqlserver.tsql_stack,sqlserver.username)
		WHERE [error_number]<>(2557) 
		AND [error_number]<>(8153)--Warning: Null value is eliminated by an aggregate or other SET operation.
		AND [error_number]<>(5701)--Changed database context to 'master'.
		AND [error_number]<>(5703)--Changed language setting to us_english.
		AND [error_number]<>(8625)--Join hint used
		AND database_id <> 4--MSDB
		AND severity > 0
		)
	ADD TARGET package0.ring_buffer(SET max_memory=(1024))
	WITH (MAX_MEMORY=524288 KB,EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS,MAX_DISPATCH_LATENCY=1 SECONDS,MAX_EVENT_SIZE=0 KB,MEMORY_PARTITION_MODE=NONE,TRACK_CAUSALITY=OFF,STARTUP_STATE=ON)
END

--See if it is running
IF NOT EXISTS (SELECT 1
			FROM sys.dm_xe_sessions
			WHERE [name] = 'ErrorSession')
--Start it up
BEGIN TRY
	ALTER EVENT SESSION ErrorSession ON SERVER STATE=START
END TRY
BEGIN CATCH 
	IF ( ERROR_NUMBER() = 25705 )
		PRINT 'Already Started, so continuing on.'
	ELSE --Unknown error 
		PRINT 'UNKNOWN ERROR!'

	;THROW;
END CATCH ;
