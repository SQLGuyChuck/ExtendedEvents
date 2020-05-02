--This doc is some working notes and scripts created by Chuck Lathrope for system health extended event shredding and Deadlock parsing with
--optimal efficiency and creating a deadicated deadlock ring_buffer for the busy system.
--No warranty expressed or implied. Use at your own risk. 
--License: Use for non-commercial purposes, at attribute to Chuck Lathrope.

/* Note for SQL 2008 users as this doc is for SQL 2012+
--SQL 2012, the Action data is defined as xml and you don't need to cast it. An example of first part of a xml_deadlock_report looks like this:
<event name="xml_deadlock_report" package="sqlserver" timestamp="2013-09-18T16:01:33.471Z">
  <data name="xml_report">
    <type name="xml" package="package0" />
    <value>
      <deadlock>
        <victim-list>
          <victimProcess id="process8fd012cf8" />
        </victim-list>
        <process-list>

--So, in SQL 2008 you would query it like so using the .value XPath method and cast its text data into XML :
SELECT CAST(XEventData.XEvent.value('(data/value)[1]', 'varchar(max)') AS XML) as DeadlockGraph
FROM
	(SELECT CAST(target_data as xml) as TargetData
	FROM sys.dm_xe_session_targets xet
	JOIN sys.dm_xe_sessions s on s.address = xet.event_session_address
	WHERE name = 'system_health') AS Data --Notice this is missing target filter because SQL 2008 system_health by default goes to ring_buffer only.
CROSS APPLY TargetData.nodes ('RingBufferTarget/event[@name="xml_deadlock_report"]') AS XEventData (XEvent)

--Note to other Internet Googlers finding solutions like this...
--If you have seen this alternate version of the CROSS APPLY, it is MUCH slower and costlier on large system_health session payloads:
--CROSS APPLY TargetData.nodes ('//RingBufferTarget/event') AS XEventData (XEvent)
--where XEventData.XEvent.value('@name', 'varchar(4000)') = 'xml_deadlock_report'
*/

--SQL 2012 version:

--NOTE: XEventData.XEvent.query('(data/value/deadlock/victim-list)[1]') [if <victim-list /> then can't save as XDL,
		-- you just need to set Maxdop=1 for query causing]

--Limitation of ring_buffer use is that we can see only about 4MB of the ring_buffer because of the DMV behind the scenes is casting binary to XML. 
--If your ring_buffer data is greater than about 4MB, you can't see it with this method. Until incoming data pushes it down (like filling a cache buffer before it sends) so you can see.
--Verion A: No temp table, but optimized XML shredding function
;WITH SystemHealth 
AS ( 
	SELECT CAST(target_data as xml) AS TargetData 
	FROM sys.dm_xe_session_targets xet 
	JOIN sys.dm_xe_sessions s ON s.address = xet.event_session_address 
	WHERE name = 'system_health' 
		AND xet.target_name = 'ring_buffer' -- We can choose to use the ring_buffer or the file target in SQL 2012, but you need file target info, described below.
	)
--Top operator helps with performance
SELECT TOP 10 CONVERT(datetime, SWITCHOFFSET(CONVERT(datetimeoffset, XEventData.XEvent.value('@timestamp','Datetime')), 
                            DATENAME(TzOffset, SYSDATETIMEOFFSET()))) As TimeCaptured,
	XEventData.XEvent.query('(data/value/deadlock)[1]') AS DeadLockGraph 
FROM SystemHealth 
CROSS APPLY TargetData.nodes ('RingBufferTarget/event[@name="xml_deadlock_report"]') AS XEventData (XEvent) 
--Slower method on systems with large system_health ring buffers -- I have seen it go beyond 5-10 minutes! With above, a few seconds at most.
--CROSS APPLY TargetData.nodes ('//RingBufferTarget/event') AS XEventData (XEvent)
--WHERE XEventData.XEvent.value('@name', 'varchar(4000)') = 'xml_deadlock_report'
OPTION (MAXDOP 4); --Helps with performance on slower predicate method as it is only one that goes parallel on my server.


--One performance tip I have seen is to put the data into a temp table and add an index, as contention seems to be high with busy systems.
IF object_id('tempdb..#SystemHealthSessionData') IS NOT NULL
	DROP TABLE #SystemHealthSessionData

-- Or if you have large dataset add XMLIndex which requires a small PK for faster querying
Create table #SystemHealthSessionData
	( Incr int not null primary key clustered,
	TargetData xml not null );

CREATE PRIMARY XML INDEX PXML_SystemHealthSessionData
ON #SystemHealthSessionData (TargetData);

INSERT INTO #SystemHealthSessionData
SELECT cast( 1 as int ) as Incr, CAST(xet.target_data as xml) as TargetData
FROM sys.dm_xe_session_targets xet
JOIN sys.dm_xe_sessions xes ON xes.address = xet.event_session_address
WHERE xes.name = 'system_health'
AND xet.target_name = 'ring_buffer'


-- Get the different events count
;WITH CTE_HealthSession AS
(
	SELECT C.query('.').value('(/event/@name)[1]', 'varchar(255)') as EventName,
	C.query('.').value('(/event/@timestamp)[1]', 'datetime') as EventTime
	FROM #SystemHealthSessionData a
	CROSS APPLY a.TargetData.nodes('/RingBufferTarget/event') as T(C)
)
SELECT EventName,
	COUNT(*) as Occurrences,
	MAX(EventTime) as LastReportedEventTime,
	MIN(EventTime) as OldestRecordedEventTime
FROM CTE_HealthSession
GROUP BY EventName
ORDER BY Occurrences DESC


-- Get statistical information about all the errors reported
;WITH CTE_HealthSession (EventXML) AS
(
SELECT C.query('.') EventXML
FROM #SystemHealthSessionData a
CROSS APPLY a.TargetData.nodes('/RingBufferTarget/event') as T(C)
),
CTE_ErrorReported (EventTime, ErrorNum) AS
(
SELECT EventXML.value('(/event/@timestamp)[1]', 'datetime') as EventTime,
EventXML.value('(/event/data/value)[1]', 'int') as ErrorNum
FROM CTE_HealthSession
WHERE EventXML.value('(/event/@name)[1]', 'varchar(255)') = 'error_reported'
)
SELECT ErrorNum,
MAX(EventTime) as LastRecordedEvent,
MIN(EventTime) as FirstRecordedEvent,
COUNT(*) as Occurrences,
b.[text] as ErrDescription
FROM CTE_ErrorReported a
INNER JOIN sys.messages b
ON a.ErrorNum = b.message_id
WHERE b.language_id = SERVERPROPERTY('LCID')
GROUP BY a.ErrorNum,b.[text]


-- Get information about each of the errors reported
;WITH CTE_HealthSession (EventXML) AS
(
SELECT C.query('.') EventXML
FROM #SystemHealthSessionData a
CROSS APPLY a.TargetData.nodes('/RingBufferTarget/event') as T(C)
WHERE C.query('.').value('(/event/@name)[1]', 'varchar(255)') = 'error_reported'
)
SELECT
EventXML.value('(/event/@timestamp)[1]', 'datetime') as EventTime,
EventXML.value('(/event/data/value)[1]', 'int') as ErrNum,
EventXML.value('(/event/data/value)[2]', 'int') as ErrSeverity,
EventXML.value('(/event/data/value)[3]', 'int') as ErrState,
EventXML.value('(/event/data/value)[5]', 'varchar(max)') as ErrText,
EventXML.value('(/event/action/value)[2]', 'varchar(10)') as Session_ID
FROM CTE_HealthSession


--Wait info
;WITH CTE_HealthSession (EventXML) AS
(
SELECT C.query('.') EventXML
FROM #SystemHealthSessionData a
CROSS APPLY a.TargetData.nodes('/RingBufferTarget/event') as T(C)
WHERE C.query('.').value('(/event/@name)[1]', 'varchar(255)') in ('wait_info','wait_info_external')
)
SELECT
EventXML.value('(/event/@timestamp)[1]', 'datetime') as EventTime,
EventXML.value('(/event/data/text)[1]', 'varchar(50)') as WaitType,
EventXML.value('(/event/data/value)[3]', 'bigint') as Duration,
EventXML.value('(/event/data/value)[4]', 'bigint') as Max_Duration,
EventXML.value('(/event/data/value)[5]', 'bigint') as Total_Duration,
EventXML.value('(/event/action/value)[2]', 'varchar(10)') as Session_ID,
EventXML.value('(/event/action/value)[3]', 'varchar(max)') as sql_text
FROM CTE_HealthSession 
ORDER BY EventTime DESC

-- Query to fetch non-yielding errors captured by the System Health Session
;WITH CTE_HealthSession (EventXML) AS
(
SELECT C.query('.') EventXML
FROM #SystemHealthSessionData a
CROSS APPLY a.TargetData.nodes('/RingBufferTarget/event') as T(C)
WHERE C.query('.').value('(/event/@name)[1]', 'varchar(255)') = 'scheduler_monitor_non_yielding_ring_buffer_recorded'
)
SELECT
EventXML.value('(/event/@timestamp)[1]', 'datetime') as EventTime,
EventXML.value('(/event/data/value)[4]', 'int') as NodeID,
EventXML.value('(/event/data/value)[5]', 'int') as SchedulerID,
CASE EventXML.value('(/event/data/value)[3]', 'int')
WHEN 0 THEN 'BEGIN'
WHEN 1 THEN 'END'
ELSE '' END AS DetectionStage,
EventXML.value('(/event/data/value)[6]', 'varchar(50)') as Worker,
EventXML.value('(/event/data/value)[7]', 'bigint') as Yields,
EventXML.value('(/event/data/value)[8]', 'bigint') as Worker_Utilization,
EventXML.value('(/event/data/value)[9]', 'bigint') as Process_Utilization,
EventXML.value('(/event/data/value)[10]', 'bigint') as System_Idle,
EventXML.value('(/event/data/value)[11]', 'bigint') as User_Mode_Time,
EventXML.value('(/event/data/value)[12]', 'bigint') as Kernel_Mode_Time,
EventXML.value('(/event/data/value)[13]', 'bigint') as Page_Faults,
EventXML.value('(/event/data/value)[14]', 'float') as Working_Set_Delta,
EventXML.value('(/event/data/value)[15]', 'bigint') as Memory_Utilization
FROM CTE_HealthSession 
ORDER BY EventTime,Worker


--Just look for deadlock information:
SELECT CONVERT(datetime, SWITCHOFFSET(CONVERT(datetimeoffset, XEventData.XEvent.value('@timestamp','Datetime')), 
                            DATENAME(TzOffset, SYSDATETIMEOFFSET()))) As TimeCaptured,
	XEventData.XEvent.query('(data/value/deadlock)[1]') AS DeadLockGraph 
FROM #SystemHealthSessionData 
--Slow predicate method:
--CROSS APPLY TargetData.nodes('//RingBufferTarget/event') AS XEventData (XEvent) 
--WHERE XEventData.XEvent.value('@name','varchar(4000)') = 'xml_deadlock_report'
--Faster predicate method:
CROSS APPLY TargetData.nodes ('RingBufferTarget/event[@name="xml_deadlock_report"]') AS XEventData (XEvent) 
WHERE CONVERT(datetime, SWITCHOFFSET(CONVERT(datetimeoffset, XEventData.XEvent.value('@timestamp','Datetime')), 
                            DATENAME(TzOffset, SYSDATETIMEOFFSET()))) > DateAdd(mi,-60,Getdate())
OPTION (MAXDOP 1);


--This is fastest method:
;WITH SystemHealth 
AS ( 
SELECT CAST(target_data as xml) AS TargetData 
FROM sys.dm_xe_session_targets st 
JOIN sys.dm_xe_sessions s ON s.address = st.event_session_address 
WHERE name = 'Deadlock_Monitor'  -- or  'system_health'
AND st.target_name = 'ring_buffer'
)
SELECT TOP 10 CONVERT(datetime, SWITCHOFFSET(CONVERT(datetimeoffset, XEventData.XEvent.value('@timestamp','Datetime')), 
                            DATENAME(TzOffset, SYSDATETIMEOFFSET()))) As TimeCaptured,
	XEventData.XEvent.query('(data/value/deadlock)[1]') AS DeadLockGraph 
FROM SystemHealth 
CROSS APPLY TargetData.nodes ('RingBufferTarget/event[@name="xml_deadlock_report"]') AS XEventData (XEvent) 
--If you don't need date filter, remove and rely on TOP operator (you could miss data) as it will speed up query.
WHERE CONVERT(datetime, SWITCHOFFSET(CONVERT(datetimeoffset, XEventData.XEvent.value('@timestamp','Datetime')), 
                            DATENAME(TzOffset, SYSDATETIMEOFFSET()))) > '2013-09-24 00:00:00'
OPTION (MAXDOP 4); --Doesn't make noticable difference on my server as it doesn't go parallel.


 

--See all ring buffer info just for giggles.
SELECT
 x.y.query('.') [XML]
,x.y.value('(@name)[1]', 'VARCHAR(MAX)') [Event]
,x.y.value('(@timestamp)[1]', 'datetime') [RunDate]
,x.y.value('(action[@name="sql_text"]/value)[1]','VARCHAR(MAX)') [Query]
,x.y.value('(data[@name="duration"]/value)[1]','BIGINT')/1000000 [Duration_Seconds]
,x.y.value('(action[@name="username"]/value)[1]','VARCHAR(MAX)') [User]
FROM #SystemHealthSessionData
 --(
 -- SELECT
 -- CAST([target_data] as XML) [targetdata]
 -- FROM sys.dm_xe_session_targets xet
 -- INNER JOIN sys.dm_xe_sessions s ON s.[address] = xet.[event_session_address]
 -- WHERE s.[name] = 'system_health'
 -- AND xet.target_name = 'ring_buffer'
 --) z
CROSS APPLY [targetdata].nodes('/RingBufferTarget/event') AS x(y)




-- Look at Active Session Information
--https://docs.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-xe-sessions-transact-sql?view=sql-server-ver15
SELECT 
   s.name, 
      ses.max_memory, 
   ses.event_retention_mode_desc,
   ses.max_dispatch_latency,
   ses.max_event_size,
   ses.memory_partition_mode_desc,
   ses.track_causality,
   ses.startup_state,
   s.pending_buffers,
--   s.total_regular_buffers,
--   s.regular_buffer_size,
--   s.total_large_buffers,
--   s.large_buffer_size,
   s.total_buffer_size,
   s.buffer_policy_desc,
   s.flag_desc,
   s.dropped_event_count,
   s.dropped_buffer_count,
--   s.blocked_event_fire_time,
   s.create_time,
   s.largest_event_dropped_size,
   s.total_bytes_generated
FROM sys.dm_xe_sessions AS s
JOIN sys.server_event_sessions as ses on ses.name = s.name
WHERE s.[Name] = 'Deadlock_Monitor';
--See a largest_event_dropped_size > regular_buffer_size ? May want to increase its size. 


-- Get target option information
SELECT 
   ses.name AS session_name,
   sest.name AS target_name,
   sesf.name AS option_name,
   sesf.value AS option_value
FROM sys.server_event_sessions AS ses
INNER JOIN sys.server_event_session_targets AS sest
   ON ses.event_session_id = sest.event_session_id
LEFT JOIN sys.server_event_session_fields AS sesf
   ON sest.event_session_id = sesf.event_session_id
   AND sest.target_id = sesf.object_id
WHERE ses.name = 'Deadlock_Monitor'


--SystemHealth in SQL 2012 has two targets, a file and buffer, lets get the target file details.
Declare @FileLocation Varchar(500)

Select @FileLocation = CAST( xet.target_data AS XML ).value('(EventFileTarget/File/@name)[1]', 'VARCHAR(MAX)')
FROM sys.dm_xe_sessions xes
INNER JOIN sys.dm_xe_session_targets xet ON xes.address = xet.event_session_address
WHERE xes.name = 'system_health' AND xet.target_name = 'event_file'

Print @filelocation

--Use the variable to see data with fn_xe_file_target_read_file
SELECT CAST(event_data as XML).query('//event/data/value/deadlock[1]')
from sys.fn_xe_file_target_read_file ( @FileLocation,NULL,NULL,NULL)
Where [object_name] = 'xml_deadlock_report'--Nice easy filter for us with file targets!

/* Works fast on a small file, how about a bigger one (e.g. last rollover version)
C:\Program Files\Microsoft SQL Server\MSSQL11.MSSQLSERVER\MSSQL\Log\system_health_0_130234815001990000.xel
xp_cmdshell 'dir "C:\Program Files\Microsoft SQL Server\MSSQL11.MSSQLSERVER\MSSQL\Log" *.xel'

09/12/2013  10:45 AM         5,197,824 system_health_0_130234371004150000.xel
09/12/2013  10:45 AM           991,232 system_health_0_130234815001990000.xel

-- Override with older version to see time it takes
--set @filelocation = 'system_health_0_130234371004150000.xel'

<event name="xml_deadlock_report" package="sqlserver" timestamp="2013-09-12T19:54:40.432Z">
  <data name="xml_report">
    <value>
      <deadlock>
*/


--Nice use of a variable to get max dispatch latency to get 5 captures in a row based on the time.
SET QUOTED_IDENTIFIER ON ;

DECLARE @startdate datetime2 = '4/1/2020', @time datetime, @rowcount int, @max_iterations int = 5 ;

SELECT @rowcount = 0, @time = DATEADD (ms,max_dispatch_latency,0)
FROM sys.server_event_sessions
WHERE name = 'Deadlock_Monitor' ;

WHILE @rowcount = 0 AND @max_iterations > 0
BEGIN
       WITH ring_buffer ( xmlcol )
       AS (
              SELECT CONVERT(XML, xet.target_data) as ring_buffer
              FROM sys.dm_xe_sessions xes
              JOIN sys.dm_xe_session_targets xet ON xet.event_session_address = xes.[address]
              WHERE xes.name = 'Deadlock_Monitor' 
       )
       SELECT CAST(T2.evntdata.value('(@timestamp)[1]','varchar(24)') AS datetime2) AS [TimeCaptured]
              ,CAST(T2.evntdata.value('(data[@name="xml_report"]/value)[1]','varchar(max)') AS XML) AS deadlock_report
       FROM ring_buffer
       CROSS APPLY xmlcol.nodes('/RingBufferTarget/event[@timestamp > sql:variable("@startdate") and @name="xml_deadlock_report"]') as T2(evntdata) ;

       SET @rowcount = @@ROWCOUNT ;

       IF @rowcount = 0
              WAITFOR DELAY @time ;

       SET @max_iterations-=1 ;
END


-------------------------------------------------------------
--FINAL Solution I use on all my servers:
--With file rollover, you could miss some data just after a file rollover, so I decided to go with a dedicated Deadlock EE session.

Declare @MinutesInPast SMALLINT = 60;

--Check for existance
IF NOT EXISTS (SELECT event_session_address
			FROM sys.dm_xe_session_targets xet
			INNER JOIN sys.dm_xe_sessions xes ON ( xes.address = xet.event_session_address )
			WHERE xes.name = 'Deadlock_Monitor'
			AND xet.target_name = 'ring_buffer')
--It must not be started, or it doesn't exist
BEGIN TRY
	DECLARE @ErrorMessage NVARCHAR(4000),
			 @ErrorSeverity INT ,
			 @ErrorState INT ;
	--Attempt to start deadlock session
	ALTER EVENT SESSION Deadlock_Monitor ON SERVER STATE=START
END TRY
BEGIN CATCH 
	-- Error is the deadlock session doesn't exist, let's try to create it.
	IF ( ERROR_NUMBER() = 15151 )
	BEGIN
		BEGIN TRY
			--Try to create
			CREATE EVENT SESSION Deadlock_Monitor ON SERVER 
			ADD EVENT sqlserver.xml_deadlock_report(ACTION(package0.collect_system_time)) 
			ADD TARGET package0.ring_buffer(SET max_events_limit=(100), max_memory=1024)--KB
			WITH (MAX_MEMORY = 1MB, STARTUP_STATE=ON) --Session memory limited also.

			--Try to start again now
			ALTER EVENT SESSION Deadlock_Monitor ON SERVER STATE=START
		END TRY
		BEGIN CATCH
			SELECT  @ErrorMessage = ERROR_MESSAGE() ,
					@ErrorSeverity = ERROR_SEVERITY() ,
					@ErrorState = ERROR_STATE() ;
                   
			RAISERROR (@ErrorMessage, -- Message text.
				@ErrorSeverity, -- Severity.
				@ErrorState -- State.
				) ;
		END CATCH
	END
	ELSE IF ( ERROR_NUMBER() = 25705 )
		PRINT 'Already Started, so continuing on.'
	ELSE --Unknown error 
		BEGIN
			SELECT  @ErrorMessage = ERROR_MESSAGE() ,
					@ErrorSeverity = ERROR_SEVERITY() ,
					@ErrorState = ERROR_STATE() ;
                   
			RAISERROR (@ErrorMessage, -- Message text.
				@ErrorSeverity, -- Severity.
				@ErrorState -- State.
				) ;
		END
END CATCH ;


--Now store it in a table or just view (Table insert commented out).
IF (@@microsoftversion / 0x1000000) & 0xff >= 11 --SQL 2012 version or higher
BEGIN
	--INSERT INTO DeadLockEvents (TimeCaptured,DeadLockGraph)
	SELECT CONVERT(datetime, SWITCHOFFSET(CONVERT(datetimeoffset, XEventData.XEvent.value('@timestamp','Datetime')), 
								DATENAME(TzOffset, SYSDATETIMEOFFSET()))) As TimeCaptured,
		XEventData.XEvent.query('(data/value/deadlock)[1]') AS DeadLockGraph 
	FROM (SELECT CAST(target_data as xml) AS TargetData 
		FROM sys.dm_xe_session_targets xet 
		JOIN sys.dm_xe_sessions xes ON xes.address = xet.event_session_address 
		WHERE xes.name = 'Deadlock_Monitor'
		AND xet.target_name = 'ring_buffer'
		) as DeadlockData 
	CROSS APPLY TargetData.nodes ('RingBufferTarget/event[@name="xml_deadlock_report"]') AS XEventData (XEvent) 
	WHERE CONVERT(datetime, SWITCHOFFSET(CONVERT(datetimeoffset, XEventData.XEvent.value('@timestamp','Datetime')), 
						DATENAME(TzOffset, SYSDATETIMEOFFSET()))) > DateAdd(mi,-@MinutesInPast,Getdate())
END
ELSE
BEGIN
	--INSERT INTO DeadLockEvents (TimeCaptured,DeadLockGraph)
	SELECT CONVERT(datetime, SWITCHOFFSET(CONVERT(datetimeoffset, XEventData.XEvent.value('@timestamp','Datetime')), 
								DATENAME(TzOffset, SYSDATETIMEOFFSET()))) As TimeCaptured,
			CAST(XEventData.XEvent.value('(data/value)[1]', 'varchar(max)') AS XML) as DeadlockGraph
	FROM
		(SELECT CAST(target_data as xml) as TargetData
		FROM sys.dm_xe_session_targets xet
		JOIN sys.dm_xe_sessions xes on xes.address = xet.event_session_address
		WHERE name = 'system_health') AS DeadlockData --Notice this is missing target filter because SQL 2008 system_health by default goes to ring_buffer only.
	CROSS APPLY TargetData.nodes ('RingBufferTarget/event[@name="xml_deadlock_report"]') AS XEventData (XEvent)
	WHERE CONVERT(datetime, SWITCHOFFSET(CONVERT(datetimeoffset, XEventData.XEvent.value('@timestamp','Datetime')), 
						DATENAME(TzOffset, SYSDATETIMEOFFSET()))) > DateAdd(mi,-@MinutesInPast,Getdate())
END


--Have a look at data (re-query ring_buffer, not from table)
--One performance tip I have seen is to put the data into a temp table and add an index, as contention seems to be high with busy systems.
IF object_id('tempdb..#DeadlockMonitorSessionData') IS NOT NULL
	DROP TABLE #DeadlockMonitorSessionData

-- Or if you have large dataset add XMLIndex which requires a small PK for faster querying
Create table #DeadlockMonitorSessionData
	( Incr int not null primary key clustered,
	TargetData xml not null );

CREATE PRIMARY XML INDEX PXML_SystemHealthSessionData
ON #DeadlockMonitorSessionData (TargetData);

INSERT INTO #DeadlockMonitorSessionData
SELECT cast( 1 as int ) as Incr, CAST(xet.target_data as xml) as TargetData
FROM sys.dm_xe_session_targets xet
JOIN sys.dm_xe_sessions xes ON xes.address = xet.event_session_address
WHERE xes.name = 'Deadlock_Monitor'
AND xet.target_name = 'ring_buffer'

SELECT TOP 5 XEvent.query('(data/value/deadlock)[1]') AS DeadLockXML
,XEvent.value('(data/value/deadlock/process-list/process/inputbuf)[1]','varchar(MAX)') as inputbuffer
,XEvent.value('(data/value/deadlock/process-list/process/@id)[1]','varchar(200)') as ProcessID
,XEvent.value('(data/value/deadlock/process-list/process/@currentdbname)[1]','varchar(200)') as currentdbname
,XEvent.value('(data/value/deadlock/process-list/process/@taskpriority)[1]','bigint') as taskpriority
,XEvent.value('(data/value/deadlock/process-list/process/@waitresource)[1]','varchar(100)') as waitresource
,XEvent.value('(data/value/deadlock/process-list/process/@lasttranstarted)[1]','varchar(50)') as lasttranstarted
,XEvent.value('(data/value/deadlock/process-list/process/@logused)[1]','bigint') as logused
,XEvent.value('(data/value/deadlock/process-list/process/@status)[1]','varchar(20)') as status
,XEvent.value('(data/value/deadlock/process-list/process/@trancount)[1]','bigint') as trancount
,XEvent.value('(data/value/deadlock/process-list/process/@clientapp)[1]','varchar(150)') as clientapp
,XEvent.value('(data/value/deadlock/process-list/process/@hostname)[1]','varchar(50)') as hostname
,XEvent.value('(data/value/deadlock/process-list/process/@loginname)[1]','varchar(150)') as loginname
,XEvent.value('(data/value/deadlock/victim-list/victimProcess/@id)[1]','varchar(20)') as VictimProcessList1
,XEvent.value('(data/value/deadlock/victim-list/victimProcess/@id)[2]','varchar(20)') as VictimProcessList2
,XEvent.value('(data/value/deadlock/process-list/process/executionStack/frame/@procname)[1]','varchar(200)') as ProcName
,XEvent.value('(data/value/deadlock/process-list/process/executionStack/frame/@line)[1]','int') as ProcLineNumber
,XEvent.value('(data/value/deadlock/process-list/process/@waitresource)[1]','varchar(30)') as waitresource
,XEvent.value('(data/value/deadlock/process-list/process/@isolationlevel)[1]','varchar(30)') as isolationlevel
FROM #DeadlockMonitorSessionData 
CROSS APPLY TargetData.nodes ('RingBufferTarget/event') AS DeadlockData (XEvent) 



--Also, have a look at: https://www.sqlshack.com/use-sql-server-extended-events-parse-deadlock-xml-generate-statistical-reports/

