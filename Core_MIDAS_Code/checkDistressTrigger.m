function fire = checkDistressTrigger(agent, modelParameters, indexT)
%CHECKDISTRESSTRIGGER  Distress-migration trigger dispatcher.
%
%   fire = checkDistressTrigger(agent, modelParameters, indexT) returns
%   true if the agent should be forced to migrate this cycle by the
%   distress overlay. The specific trigger logic is selected by
%   modelParameters.distressTriggerCode:
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
%     6 -- VARIANT F: income shock AND depleted livestock buffer
%          fire if the Variant E income-shock condition holds AND the
%          agent's buffer is below modelParameters.bufferFloor. This is
%          the empirically documented rule: households ride out a first
%          failed harvest on the buffer and move only once it is drawn
%          down to the reproductive floor. It therefore fires almost
%          exclusively in continuation years, producing first-vs-
%          continuation compounding endogenously. Requires
%          modelParameters.bufferEnabled = true (otherwise the buffer is
%          always 0 and the condition collapses to Variant E). Uses the
%          same cooldown as Variant E.
%
%   The destination logic (choosePortfolio with distressMode=true) is
%   shared across all variants -- only the trigger differs.

fire = false;

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

    case 6   % VARIANT F: income shock AND depleted buffer
        % The buffer must exist for this to differ from Variant E.
        bufFloor = 0;
        if isfield(modelParameters, 'bufferFloor')
            bufFloor = modelParameters.bufferFloor;
        end
        fire = incomeShockFires(agent, modelParameters, indexT) && ...
               (agent.buffer < bufFloor);

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
function fires = incomeShockFires(agent, modelParameters, indexT)
% Shared Variant E / F condition: realised income over the last cycleLength
% quarters is below distressIncomeDropFrac x the mean of the preceding
% distressIncomeWindowYears annual totals, subject to the re-fire cooldown.
    fires = false;
    cl    = modelParameters.cycleLength;
    wy    = modelParameters.distressIncomeWindowYears;
    needQ = (wy + 1) * cl;              % last year + baseline window
    histEnd = indexT - 1;              % current-quarter income realised after decisions

    if histEnd >= needQ && ...
       (histEnd - needQ + 1) > agent.DOB && ...
       length(agent.personalIncomeHistory) >= histEnd && ...
       (indexT - agent.lastDistressMoveT) >= modelParameters.distressCooldownQuarters

        inc = agent.personalIncomeHistory;
        lastYear = sum(inc(histEnd - cl + 1 : histEnd));
        baseline = 0;
        for k = 1:wy
            idx0 = histEnd - (k + 1) * cl + 1;
            baseline = baseline + sum(inc(idx0 : idx0 + cl - 1));
        end
        baseline = baseline / wy;

        fires = baseline > 0 && ...
                lastYear < modelParameters.distressIncomeDropFrac * baseline;
    end
end
