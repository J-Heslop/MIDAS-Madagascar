function [fire, diag] = checkDistressTrigger(agent, modelParameters, indexT, oracleYF)
%CHECKDISTRESSTRIGGER  Distress-migration trigger dispatcher.
%
%   fire = checkDistressTrigger(agent, modelParameters, indexT, oracleYF)
%   returns true if the agent should be forced to migrate this cycle by
%   the distress overlay. oracleYF (optional) is only used by case 7: a
%   2-element vector [agYF_thisYear, agYF_lastYear] at the agent's
%   current location, supplied by midasMainLoop. The specific trigger
%   logic is selected by modelParameters.distressTriggerCode:
%
%     0 -- disabled (always returns false)
%     1 -- VARIANT A: consecutive food-insecure years
%          fire if agent.consecutiveFIYears >= modelParameters.distressN
%          Uses the year-end FI flag (wealth_end < wealth_start).
%          Counter is updated in midasMainLoop at year-end.
%
%     2 -- VARIANT B: wealth threshold + duration
%          fire if agent.quartersBelowWealthThreshold >= modelParameters.distressN_quarters
%          Counts consecutive quarters with wealth below
%          modelParameters.distressWealthThreshold. Counter is updated
%          in midasMainLoop at the end of each quarter.
%
%     3 -- VARIANT C: cumulative wealth shortfall over rolling window
%          fire if sum_{t in window}(max(0, threshold - wealth_t))
%                 >= modelParameters.distressCriticalShortfall
%          Window length is modelParameters.distressShortfallWindowYears,
%          read off agent.wealthHistory (populated each quarter in the
%          main loop). Computed on-the-fly each year-end.
%
%     4 -- VARIANT D: stochastic depth-dependent (per-quarter draw)
%          fire if rand() < 1 - exp(-alpha * (threshold - wealth) / threshold)
%          when wealth < threshold; otherwise never fire. No state
%          maintenance needed.
%
%     5 -- VARIANT E: income shock (drop vs own trailing mean)
%          fire if the agent's realised income over the last cycleLength
%          quarters is below distressIncomeDropFrac x the mean of the
%          preceding distressIncomeWindowYears annual totals.
%          Rationale (chain audit, 2026-07): the drought signal in the
%          model is alive at the INCOME link (-9% in kere years, scaling
%          with droughtScaleFactor) but completely dead at the
%          wealth/FI link, where variants A-D all read their state.
%          Variant E conditions on the last live link. A cooldown
%          (distressCooldownQuarters since the agent's last distress
%          move) prevents immediate re-firing while the trailing window
%          still spans the shock.
%
%     6 -- VARIANT F: income shock AND MATERIAL consumption shortfall
%          fire if the Variant E income-shock condition holds AND the
%          agent's most recent year-end consumption shortfall (unmet
%          food gap AFTER drawing down the livestock/grain buffer;
%          agent.lastShortfall, set in midasMainLoop) exceeds the
%          materiality threshold distressShortfallAbs (a fraction of
%          annual subsistence, default 0.1 ~ one month of food; 0 =
%          legacy strict-positive behaviour).
%          This is the empirically documented rule: households ride out
%          a first failed harvest on the buffer and move only once it
%          can no longer cover consumption. shortfall > 0 implies the
%          buffer was already drawn to its reproductive floor, so this
%          subsumes the earlier "buffer < floor" condition while being
%          robust to exactly-at-floor states (drawdown stops AT the
%          floor, so the strict < test was nearly unfireable).
%          Requires modelParameters.bufferEnabled = true (otherwise
%          lastShortfall is never set and the trigger never fires).
%          Uses the same cooldown as Variant E.
%
%     7 -- ORACLE: exogenous-forcing trigger (diagnostic upper bound)
%          fire if agYF at the agent's location was below
%          oracleAgYFThreshold in BOTH this year and last year (two
%          consecutive drought years), reading the climate forcing
%          directly rather than any agent state. This bounds what ANY
%          agent-state trigger (A-F) can achieve and tests the
%          downstream pipeline (distress-mode choosePortfolio -> flows
%          -> detrended metrics) in isolation: if the oracle cannot
%          produce first-vs-continuation compounding in the metrics,
%          the bottleneck is downstream (churn dilution, destination
%          congestion, metric) and no agent-state engineering will fix
%          it. Fires only in continuation years by construction. NOT
%          for production runs -- diagnostic only.
%
%   The destination logic (choosePortfolio with distressMode=true) is
%   shared across all variants -- only the trigger differs.

if nargin < 4
    oracleYF = [];
end

fire = false;

% Optional second output: per-condition diagnostics for the distress trace
% (see midasMainLoop.m). Populated fully only by case 6 (Variant F); other
% cases return the initialised defaults. Kept cheap: callers that don't
% request it pay nothing beyond this struct build.
diag = struct('lastYearIncome', NaN, 'baselineIncome', NaN, ...
              'dropThreshold',  NaN, 'incomeShock',    false, ...
              'historyOK',      false, 'cooldownOK',   false, ...
              'lastShortfall',  NaN);

if ~isfield(modelParameters, 'distressMigrationEnabled') || ...
   ~modelParameters.distressMigrationEnabled
    return;
end

code = modelParameters.distressTriggerCode;

switch code
    case 1   % VARIANT A: consecutive FI years
        fire = agent.consecutiveFIYears >= modelParameters.distressN;

    case 2   % VARIANT B: wealth threshold + duration
        fire = agent.quartersBelowWealthThreshold >= modelParameters.distressN_quarters;

    case 3   % VARIANT C: cumulative wealth shortfall over rolling window
        windowQ  = modelParameters.distressShortfallWindowYears * modelParameters.cycleLength;
        startIdx = max(1, indexT - windowQ + 1);
        cum = 0;
        for t = startIdx:indexT
            if t <= length(agent.wealthHistory) && ~isempty(agent.wealthHistory{t})
                cum = cum + max(0, modelParameters.distressWealthThreshold - agent.wealthHistory{t});
            end
        end
        fire = cum >= modelParameters.distressCriticalShortfall;

    case 4   % VARIANT D: stochastic depth-dependent
        if agent.wealth < modelParameters.distressWealthThreshold
            depth = (modelParameters.distressWealthThreshold - agent.wealth) / ...
                    modelParameters.distressWealthThreshold;
            p = 1 - exp(-modelParameters.distressStochasticAlpha * depth);
            fire = rand() < p;
        end

    case 5   % VARIANT E: income shock vs own trailing mean
        fire = incomeShockFires(agent, modelParameters, indexT);

    case 6   % VARIANT F: SOLVENCY (redesigned 2026-07-28)
        % A household migrates when its way of life is no longer viable:
        % after spending its income and drawing its stock down to the
        % reproductive floor, it still cannot meet the year's subsistence.
        % agent.lastShortfall is that unmet amount, set at year-end in
        % midasMainLoop's buffer block.
        %
        % The income-shock condition (Variant E) has been REMOVED, not
        % merely disabled. It tested a year-on-year ratio, which cannot
        % distinguish a household that absorbs a 40% drop on its stores
        % from one destroyed by a 10% drop with nothing behind it -- and
        % its window length (distressIncomeWindowYears) was the single
        % strongest driver of the drought metric in the sensitivity
        % analysis at 0.415, i.e. the measurement choice moved the result
        % more than the drought did. Solvency has no such parameter.
        %
        % The multi-year response is emergent: year one the stock covers
        % most of the requirement, year two it sits at the floor and the
        % full inflated requirement falls on income alone.
        %
        % REQUIRES bufferEnabled = true (lastShortfall is only ever set in
        % the buffer block; without it the trigger is inert by design).
        sfThresh = 0;
        if isfield(modelParameters, 'distressShortfallAbs')
            sfThresh = modelParameters.distressShortfallAbs;
        end
        cooldownOK = (indexT - agent.lastDistressMoveT) >= ...
                     modelParameters.distressCooldownQuarters;

        % lastShortfall is refreshed annually but the trigger is polled every
        % quarter, so the cooldown stops one bad year firing four times.
        diag.lastShortfall = agent.lastShortfall;
        diag.cooldownOK    = cooldownOK;
        diag.historyOK     = true;
        diag.incomeShock   = false;   % retained for trace-format stability

        fire = cooldownOK && (agent.lastShortfall > sfThresh);

    case 106  % LEGACY Variant F (income shock AND shortfall) -- kept only so
              % pre-2026-07-28 runs remain reproducible. Not for new work.
        % REDESIGN 2026-07-10: the original condition was
        % "buffer < bufferFloor", but drawdown stops exactly AT the floor
        % so a farmer's buffer lives in [floor, cap] and the strict <
        % test was nearly unfireable (only drought mortality nudged a
        % floored buffer a hair below). agent.lastShortfall > 0 is the
        % robust equivalent: the year's food gap exceeded what the
        % buffer above the floor could cover -- i.e. the buffer is
        % depleted AND the household could not eat. Set at year-end in
        % midasMainLoop's buffer block; stays 0 when bufferEnabled is
        % false, so the trigger is inert without the buffer.
        [shock, sd] = incomeShockFires(agent, modelParameters, indexT);
        diag.lastYearIncome = sd.lastYearIncome;
        diag.baselineIncome = sd.baselineIncome;
        diag.dropThreshold  = sd.dropThreshold;
        diag.historyOK      = sd.historyOK;
        diag.cooldownOK     = sd.cooldownOK;
        diag.incomeShock    = shock;
        diag.lastShortfall  = agent.lastShortfall;
        % MATERIALITY THRESHOLD (2026-07-21): the shortfall must exceed
        % distressShortfallAbs (a fraction of annual subsistence, derived
        % in midasMainLoop from distressShortfallFrac) rather than merely
        % being positive. The strict > 0 test was chronically satisfied,
        % decoupling firing from buffer state; requiring a MATERIAL unmet
        % gap (~> 1 month of food) makes the buffer's absorption capacity
        % decide whether a bad year crosses the line. Missing field or
        % frac = 0 -> threshold 0 = legacy behaviour.
        sfThresh = 0;
        if isfield(modelParameters, 'distressShortfallAbs')
            sfThresh = modelParameters.distressShortfallAbs;
        end
        fire = shock && (agent.lastShortfall > sfThresh);

    case 7   % ORACLE: two consecutive drought years at agent's location
        % Diagnostic upper bound -- reads the forcing, not agent state.
        % oracleYF = [agYF_thisYear, agYF_lastYear] is supplied by
        % midasMainLoop (empty when the arm is inactive). During the
        % first simulation year the two entries coincide (year index
        % clamped), so treat with care in analysis; postSpin gating at
        % the call site plus the cooldown keep spinup quiet.
        thr = 0.8;
        if isfield(modelParameters, 'oracleAgYFThreshold')
            thr = modelParameters.oracleAgYFThreshold;
        end
        cooldownQ = 4;
        if isfield(modelParameters, 'distressCooldownQuarters')
            cooldownQ = modelParameters.distressCooldownQuarters;
        end
        fire = numel(oracleYF) == 2 && ...
               oracleYF(1) < thr && oracleYF(2) < thr && ...
               (indexT - agent.lastDistressMoveT) >= cooldownQ;

    otherwise
        % Unknown code -> treat as disabled rather than erroring out.
        % Log a warning at most once per simulation to avoid spam.
        persistent warned;
        if isempty(warned)
            warning('checkDistressTrigger:unknownCode', ...
                'Unknown distressTriggerCode=%d. Falling back to disabled.', code);
            warned = true;
        end
        fire = false;
end

end

% =========================================================================
function [fires, diag] = incomeShockFires(agent, modelParameters, indexT)
% Shared Variant E / F condition: realised NET income over the last
% cycleLength quarters is below distressIncomeDropFrac x the mean of the
% preceding distressIncomeWindowYears annual totals, subject to the re-fire
% cooldown and a minimum-baseline guard.
%
% NET INCOME (2026-07-28): reads agent.netIncomeHistory -- income after the
% drought-scaled subsistence cost, before remittances. It previously read
% personalIncomeHistory (GROSS), which could not see the drought: measured
% on gross income the condition fired at 1.9% in drought years against 1.75%
% in normal years, and the median income ratio in kere years (1.017) was
% marginally HIGHER than across all years (1.004). Most of a kere's damage
% falls on the expenditure side, and subsistNow is the only drought channel
% reaching non-farming agents.
%
% Second output (optional) exposes the per-condition components for the
% distress trace.
    fires = false;
    cl    = modelParameters.cycleLength;
    wy    = modelParameters.distressIncomeWindowYears;
    needQ = (wy + 1) * cl;              % last year + baseline window
    histEnd = indexT - 1;              % current-quarter income realised after decisions

    % Defensive: netIncomeHistory is new. An agent restored from an older
    % saved state would not have it -- fail closed rather than error.
    hasNet = isprop(agent, 'netIncomeHistory') && ~isempty(agent.netIncomeHistory);

    historyOK  = hasNet && histEnd >= needQ && ...
                 (histEnd - needQ + 1) > agent.DOB && ...
                 length(agent.netIncomeHistory) >= histEnd;
    cooldownOK = (indexT - agent.lastDistressMoveT) >= modelParameters.distressCooldownQuarters;

    diag = struct('lastYearIncome', NaN, 'baselineIncome', NaN, ...
                  'dropThreshold',  NaN, 'historyOK', historyOK, ...
                  'cooldownOK', cooldownOK);

    if historyOK && cooldownOK
        inc = agent.netIncomeHistory;
        lastYear = sum(inc(histEnd - cl + 1 : histEnd));
        baseline = 0;
        for k = 1:wy
            idx0 = histEnd - (k + 1) * cl + 1;
            baseline = baseline + sum(inc(idx0 : idx0 + cl - 1));
        end
        baseline = baseline / wy;

        diag.lastYearIncome = lastYear;
        diag.baselineIncome = baseline;
        diag.dropThreshold  = modelParameters.distressIncomeDropFrac * baseline;

        % MINIMUM BASELINE GUARD: net income can be small or negative, and a
        % near-zero denominator makes the ratio explode -- households living
        % at the line would fire on noise. Excludes the chronically
        % sub-subsistence, whose condition is poverty rather than shock.
        % Absolute units, published by midasMainLoop as a fraction of annual
        % subsistence. Falls back to >0 if absent (legacy behaviour).
        minBase = 0;
        if isfield(modelParameters, 'distressMinBaseline')
            minBase = modelParameters.distressMinBaseline;
        end

        fires = baseline > minBase && lastYear < diag.dropThreshold;
    end
end
