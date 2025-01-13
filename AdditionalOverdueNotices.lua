luanet.load_assembly("log4net");

local types = {}
types["log4net.LogManager"] = luanet.import_type("log4net.LogManager");
local log = types["log4net.LogManager"].GetLogger("AtlasSystems.Addons.AdditionalOverdueNotices");

local Settings = {};
Settings.NVTGC = GetSetting("NVTGC");
Settings.MonitorQueues = GetSetting("MonitorQueues");
Settings.EmailName = GetSetting("EmailName");
Settings.DaysBeforeNotices = GetSetting("DaysBeforeNotices");
Settings.NotificationTime = GetSetting("NotificationTime");
Settings.NotificationDaysOfWeek = GetSetting("NotificationDaysOfWeek"):lower();

local isCurrentlyProcessing = false;
local sharedServerSupport = false;
local lastCheckedDay = nil;
local hasRunToday = false;
local systemManagerAddonInterval = nil;

function Init()
    RegisterSystemEventHandler("SystemTimerElapsed", "TimerElapsed");
end

function TimerElapsed()
    if not isCurrentlyProcessing then
        DailyRunTimeReset();

        if hasRunToday or not IsTimeToRun() then
            return;
        end
    
        local connection = CreateManagedDatabaseConnection();

        local success, transactionNumbersOrErr = pcall(function()
            connection:Connect();
            SetSharedServerSupport(connection);
    
            local usersTable = "Users";
            if sharedServerSupport then
                usersTable = "UsersALL";
            end
    
            local queryString = [[SELECT TransactionNumber FROM Transactions 
            INNER JOIN ]] .. usersTable .. [[ ON ]] .. usersTable .. [[.Username = Transactions.Username 
            WHERE TransactionStatus = 'Checked Out to Customer'
            AND DATEADD(day, ]] .. Settings.DaysBeforeNotices .. [[, DueDate) <= CAST(GETDATE() AS DATE)]];
    
            if Settings.NVTGC:find("%w") then
                Settings.NVTGC = "'" .. Settings.NVTGC:gsub("%s*,%s*", ","):gsub(",", "','") .. "'";
                queryString = queryString .. " AND NVTGC IN(" .. Settings.NVTGC .. ")";
            end
    
            log:Debug("Querying the database with querystring: " .. queryString);

            connection.QueryString = queryString;
            local queryResults = connection:Execute();
    
            local transactionNumbers = {};
            if queryResults.Rows.Count > 0 then
                for i = 0, queryResults.Rows.Count - 1 do
                    transactionNumbers[#transactionNumbers+1] = queryResults.Rows:get_Item(i):get_Item("TransactionNumber");
                end
            end
    
            return transactionNumbers;
        end);
    
        connection:Dispose();
    
        if success then
            hasRunToday = true;

            if #transactionNumbersOrErr > 0 then
                ProcessDataContexts("TransactionNumber", transactionNumbersOrErr, "SendOverdueNotices")
            end
        else
            log:Error("An error occurred when retrieving transaction info from the database: " .. tostring(TraverseError(transactionNumbersOrErr)));
        end

        isCurrentlyProcessing = false;
    else
        log:Debug("Still processing requests for additional overdue notices.");
    end
end

function DailyRunTimeReset()
    local today = os.date("%A"):lower();

    if lastCheckedDay ~= today then
        -- We don't want to log this on the first run of the addon where lastCheckedDay will be nil.
        if lastCheckedDay then
            log:Debug("Date has changed. hasRunToday will be set to false and cached SystemManagerAddonInterval will be updated.");
        end
        hasRunToday = false;
        lastCheckedDay = today;

        -- Update cached value for SystemManagerAddonInterval in case it has changed.
        local connection = CreateManagedDatabaseConnection();
        local success, err = pcall(function()
            connection:Connect();
            CacheSystemManagerAddonInterval(connection);
        end);

        connection:Dispose();

        if not success then
            log:Error("An error occurred when retrieving SystemManagerAddonInterval from the database: " .. tostring(TraverseError(err)));
        end

    end
    
    if hasRunToday then
        log:Debug("Additional overdue notices have already run today and will not run again until the next designated day.");
    end
end

function IsTimeToRun()
    -- Cache SystemManagerAddonInterval if it is not cached already.
    if not systemManagerAddonInterval then
        local connection = CreateManagedDatabaseConnection();
        local success, err = pcall(function()
            connection:Connect();
            CacheSystemManagerAddonInterval(connection);

        end);

        connection:Dispose();

        if not success then
            log:Error("An error occurred when retrieving SystemManagerAddonInterval from the database: " .. tostring(TraverseError(err)));
        end
    end
    
    local currentDayOfWeek = os.date("%A"):lower();
    local currentDate = os.date("%m/%d/%Y");
    local thisMonth, today, thisYear = tostring(currentDate):match("(%d+)/(%d+)/(%d+)");
    local currentTimeSeconds = os.time();
    
    local runTimeHour, runTimeMinute = Settings.NotificationTime:match("(%d%d)(%d%d)");
    local runTimeMinSeconds = os.time({year=thisYear, month=thisMonth, day=today, hour=runTimeHour, min=runTimeMinute});
    local runTimeMaxSeconds = runTimeMinSeconds + (systemManagerAddonInterval * 60 * 3);

    -- The addon can run between the runtime and the runtime + 3 times the SystemManagerAddonInterval.
    -- This is to prevent the addon from sending notifications immediately every time it's turned on or
    -- System Manager is restarted, which would happen if using simply currentTimeSeconds >= runTimeSeconds.
    -- The range is given in terms of the SystemManagerAddonInterval to ensure runs aren't skipped.
    if currentTimeSeconds >= runTimeMinSeconds and currentTimeSeconds <= runTimeMaxSeconds and Settings.NotificationDaysOfWeek:find(currentDayOfWeek) then
        log:Debug("Run time criteria met.");
        return true;
    end
    
    -- Values logged for support when addon does not run.
    log:Debug("Criteria for run time not met. \nCurrent time: " .. os.date("%H%M", currentTimeSeconds) .. "\nMinimum run time: " .. os.date("%H%M", runTimeMinSeconds) .. "\nMaximum runtime: " .. os.date("%H%M", runTimeMaxSeconds) .. "\nCurrent day of the week: " .. currentDayOfWeek);

    return false;
end

function SendOverdueNotices()
    local transactionNumber = GetFieldValue("Transaction", "TransactionNumber");
    local lastOverdueNoticeSent = GetFieldValue("Transaction", "LastOverdueNoticeSent");

    -- This should never happen if the overdue custkeys and addon are configured correctly, but just in case we'll set it to zero.
    if not lastOverdueNoticeSent then
        lastOverdueNoticeSent = 0;
    end

    local newNoticeNumber = lastOverdueNoticeSent + 1;

    log:Debug("Sending overdue notice #" .. newNoticeNumber .. " with template " .. Settings.EmailName .. " for transaction " .. transactionNumber .. ".");

    SetFieldValue("Transaction", "LastOverdueNoticeSent", newNoticeNumber);
    SaveDataSource("Transaction");
    ExecuteCommand("SendTransactionNotification", {transactionNumber, Settings.EmailName});
end

function SetSharedServerSupport(connection)
    connection.QueryString = "SELECT Value FROM Customization WHERE CustKey = 'SharedServerSupport' AND NVTGC = 'ILL'";
    local value = connection:ExecuteScalar();

    if value == "Yes" then
        log:Debug("Shared Server Support enabled");
        sharedServerSupport = true;
    else
        log:Debug("Shared Server Support not enabled");
        sharedServerSupport = false;
    end
end

function CacheSystemManagerAddonInterval(connection)
    connection.QueryString = "SELECT Value FROM Customization WHERE CustKey = 'SystemManagerAddonInterval' AND NVTGC = 'ILL'";
    local value = connection:ExecuteScalar();

    if value and value ~= "" then
        log:Debug("Caching SystemManagerAddonInterval customization key. Value: " .. value);
        systemManagerAddonInterval = tonumber(value);
    else
        log:Debug("Valid value not found when attempting to cache the SystemManagerAddonInterval customization key. Using system default of 5.");
        systemManagerAddonInterval = 5;
    end
end

function TraverseError(e)
    if not e.GetType then
        -- Not a .NET type
        return e;
    else
        if not e.Message then
            -- Not a .NET exception
            return e;
        end
    end

    log:Debug(e.Message);

    if e.InnerException then
        return TraverseError(e.InnerException);
    else
        return e.Message;
    end
end

function OnError(err)
    -- To ensure the addon doesn't get stuck in processing if it encounters an error.
    isCurrentlyProcessing = false;
    log:Error(tostring(TraverseError(err)));
end