function [S, T] = wealth_decomposition(traceDir)
% WEALTH_DECOMPOSITION  Attribute the wealth decline to its accounting channels.
%
%   [S, T] = wealth_decomposition                      % ./Outputs
%   [S, T] = wealth_decomposition('./Outputs')
%
% THE QUESTION
% Mean agent wealth is negative from early in every run and declines to 2085.
% Wealth still gates voluntary migration (the reserve test in choosePortfolio),
% so the level is not inert. This decides whether the decline is an accounting
% error or the accumulated consequence of a calibration choice, by closing the
% books rather than by ablating mechanisms.
%
% WHY NOT ABLATION RUNS
% Setting access costs to zero changes which layers agents choose, because the
% cost enters the value function. The resulting wealth difference then mixes
% the direct saving with a behavioural response, and the separate ablations do
% not sum to the total. Subsistence is worse: it drives food insecurity, sets
% the surplus that network sharing is assessed on, and feeds the distress
% trigger. The identity below is exact and needs one run.
%
% THE IDENTITY
% Within a quarter, in the order midasMainLoop executes:
%
%   wealth_end = wealth_preChoice          (wealth entering the quarter)
%              - moveAccessCost            (choosePortfolio.m:767 and :800)
%              + netIncome                 (income net of remittances paid out)
%              - subsistNow                (subsistence, drought-inflated)
%              + wealth_resid              (MUST be zero -- see below)
%
% Between quarters, the livestock/grain buffer trades wealth for stored food
% (midasMainLoop.m:1541 and :1577) and estates are bequeathed (:496), all
% AFTER the trace row is written. So
%
%   carryGap(t) = wealth_preChoice(t+1) - wealth_end(t)
%
% captures the buffer and inheritance channel. Together these exhaust every
% write to agent.wealth in the codebase.
%
% READING THE RESULT
% wealth_resid is the bug detector. It is the only term with no mechanism
% behind it, so any non-zero value is unexplained arithmetic between the
% capture of wealth_start and the update at midasMainLoop.m:1174.
%
% NOTE ON AN EARLIER READING OF wealth_resid. Before the instrumentation this
% script depends on, wealth_resid was identically zero in every trace -- not
% because the books balanced but because moving and access costs are debited
% ~270 lines BEFORE wealth_start is captured, so they fell outside the window
% entirely. A zero residual proved only that the two largest discretionary
% channels were unmeasured. If wealth_preChoice is absent from the CSV, the
% trace predates the fix and this script says so rather than reporting a
% decomposition with two channels silently missing.

if nargin < 1 || isempty(traceDir); traceDir = './Outputs'; end
traceDir = char(traceDir);
f = fullfile(traceDir, 'agent_life_history.csv');
if ~exist(f, 'file')
    error('wealth_decomposition:noTrace', ...
          ['Not found: %s\nRun a local trace first (run_agent_trace.m). This ' ...
           'needs the per-agent life history, not calibration output.'], f);
end

% Same delimiter-safe reader the summary scripts use: MATLAB's auto-detection
% picks the underscore in MC_Run_T001_12_..._slim.mat over the comma and
% collapses a wide CSV to six unnamed columns.
if exist('readSummaryCsv', 'file') == 2
    T = readSummaryCsv(f);
else
    T = readtable(f, 'Delimiter', ',', 'ReadVariableNames', true, ...
                     'VariableNamingRule', 'preserve');
end
vn = T.Properties.VariableNames;

need = {'agentID','t','wealth_preChoice','moveAccessCost','netIncome', ...
        'subsistNow','wealth_resid','wealth_start','wealth_end'};
missing = need(~ismember(need, vn));
if ~isempty(missing)
    if any(strcmp(missing, 'wealth_preChoice'))
        error('wealth_decomposition:staleTrace', ...
              ['%s predates the moving/access-cost instrumentation, so the two ' ...
               'discretionary channels cannot be measured from it.\n' ...
               'Missing: %s\n\nRe-run the local trace with the current ' ...
               'Core_MIDAS_Code/midasMainLoop.m (run_agent_trace.m). It is a ' ...
               'small single-threaded run, not a campaign.'], ...
              f, strjoin(missing, ', '));
    end
    error('wealth_decomposition:missingCols', ...
          'Missing columns in %s: %s', f, strjoin(missing, ', '));
end

T = sortrows(T, {'agentID','t'});
fprintf('Read %s: %d agent-quarters, %d agents, t %d-%d.\n', ...
        f, height(T), numel(unique(T.agentID)), min(T.t), max(T.t));

% Rows the instrumentation could not populate -- an agent that did not pass
% the decision loop that timestep (a newborn). Dropped and COUNTED rather than
% left to propagate: a single NaN in a sum turns the whole decomposition into
% NaN, which hides the rest of the answer behind one uninformative row.
bad = isnan(T.wealth_preChoice) | isnan(T.moveAccessCost) | ...
      isnan(T.netIncome) | isnan(T.subsistNow) | isnan(T.wealth_end);
if any(bad)
    fprintf(['Dropping %d of %d rows with incomplete instrumentation ' ...
             '(agents not seen by\nthe decision loop that timestep -- ' ...
             'normally newborns).\n'], nnz(bad), height(T));
    if nnz(bad) / height(T) > 0.05
        fprintf(2, ['That is more than 5%% of the trace. Expected a handful of ' ...
                    'newborns, not this\nmany -- check the carriers before ' ...
                    'trusting the decomposition below.\n']);
    end
    T = T(~bad, :);
end
if height(T) < 2
    error('wealth_decomposition:noUsableRows', ...
          'No usable rows remain after dropping incomplete instrumentation.');
end

% ---------------------------------------------------------------- identity
% Per-quarter check that the within-quarter identity holds exactly.
lhs = T.wealth_end;
rhs = T.wealth_preChoice - T.moveAccessCost + T.netIncome - T.subsistNow + T.wealth_resid;
identityErr = lhs - rhs;
tol = 1e-9 * max(1, max(abs(T.wealth_end)));

fprintf('\n=== 1. Does the within-quarter identity close? ===\n');
nBad = nnz(abs(identityErr) > tol);
if nBad == 0
    fprintf('Yes. All %d agent-quarters reconcile to within %.1e.\n', height(T), tol);
else
    fprintf(2, ['NO -- %d of %d agent-quarters do not reconcile (max |err| %.4g).\n' ...
                'That is an unaccounted write to agent.wealth. Investigate before\n' ...
                'interpreting anything below.\n'], nBad, height(T), max(abs(identityErr)));
end

% ---------------------------------------------------------------- residual
% wealth_resid has no mechanism behind it, so non-zero means unexplained
% arithmetic between wealth_start and the update at midasMainLoop.m:1174.
fprintf('\n=== 2. Bug detector: is wealth_resid ever non-zero? ===\n');
nRes = nnz(abs(T.wealth_resid) > tol);
if nRes == 0
    fprintf(['No. The income-and-subsistence window is clean across all %d\n' ...
             'agent-quarters, so the decline is not an arithmetic error there.\n'], ...
            height(T));
else
    fprintf(2, ['%d agent-quarters carry a non-zero residual (max %.4g, total %.4g).\n' ...
                'This IS a bug -- wealth changed by an amount no mechanism accounts for.\n'], ...
            nRes, max(abs(T.wealth_resid)), sum(T.wealth_resid));
end

% Moving/access spend in a quarter with no move is legitimate -- it is a layer
% access fee. Reported rather than flagged, because a large value here would
% mean agents are repeatedly paying to re-enter layers, which accessCodesPaid
% is supposed to prevent.
if ismember('moved', vn)
    noMove = T.moved == 0 & T.moveAccessCost > tol;
    fprintf(['\nQuarters with access spend but no move: %d (total %.4g).\n' ...
             'These are layer entry fees. A large total would suggest agents are\n' ...
             're-paying for layers they already hold (accessCodesPaid not sticking).\n'], ...
            nnz(noMove), sum(T.moveAccessCost(noMove)));
end

% ---------------------------------------------------------------- carry gap
% Between the trace row and the next quarter, the buffer trades wealth for
% stored food and estates are bequeathed. Per agent, so agent boundaries do
% not contaminate the difference.
fprintf('\n=== 3. Between-quarter channel (buffer + inheritance) ===\n');
carry = nan(height(T),1);
ids = unique(T.agentID);
for i = 1:numel(ids)
    k = find(T.agentID == ids(i));
    if numel(k) < 2; continue; end
    % Only consecutive quarters; a gap in t means the agent was not traced.
    consec = diff(T.t(k)) == 1;
    carry(k([consec; false])) = T.wealth_preChoice(k([false; consec])) - ...
                                T.wealth_end(k([consec; false]));
end
carryTot = sum(carry, 'omitnan');
fprintf('Total across %d consecutive-quarter transitions: %+.4g\n', ...
        nnz(~isnan(carry)), carryTot);
fprintf('(Negative = wealth moved into stored food; positive = food sold or estate received.)\n');

% ------------------------------------------------- debt-financed mobility
% The question this section answers: how much movement is being paid for by
% agents who cannot afford it, and through which channel.
%
% choosePortfolio applies a liquidity test -- a move is blocked if it would
% leave the agent in debt -- but ONLY when distressMode is false. Distress
% moves skip it. So an agent at negative wealth can move if and only if the
% distress trigger routed it, and every such move drives wealth further down
% with no floor beneath it.
%
% (Before 2026-09-13 this was a reserve test, post-move wealth >=
% creditMultiplier x collateral, so the threshold sat slightly ABOVE zero and a
% few solvent-but-poor agents were blocked who now are not. The conclusion this
% section draws is unchanged; the boundary moved a little.)
%
% If most move spending comes from agents already in debt, via the distress
% channel, then the voluntary channel is closed by arithmetic rather than by
% preference and the distress share of moves is an artefact of the wealth
% level, not a behavioural result.
fprintf('\n=== 4. Debt-financed mobility ===\n');
if ~ismember('isDistress', vn)
    fprintf(2, ['Trace has no isDistress column, so moves cannot be split by\n' ...
                'channel. Re-run the trace with the current midasMainLoop.m.\n']);
else
    spent    = T.moveAccessCost > tol;
    inDebt   = T.wealth_preChoice < 0;
    distress = T.isDistress > 0;

    tot = sum(T.moveAccessCost(spent));
    fprintf('Total moving + access spend: %.4g across %d agent-quarters.\n', ...
            tot, nnz(spent));
    if tot > 0
        cell4 = @(m) sum(T.moveAccessCost(spent & m));
        fprintf('\n%-34s %12s %10s\n', 'who paid', 'total', '% of spend');
        fprintf('%s\n', repmat('-', 1, 58));
        rows = { 'solvent, voluntary',  spent & ~inDebt & ~distress; ...
                 'solvent, distress',   spent & ~inDebt &  distress; ...
                 'IN DEBT, voluntary',  spent &  inDebt & ~distress; ...
                 'IN DEBT, distress',   spent &  inDebt &  distress };
        for k = 1:size(rows,1)
            v = sum(T.moveAccessCost(rows{k,2}));
            fprintf('%-34s %12.4g %9.1f%%\n', rows{k,1}, v, 100*v/tot);
        end
        fprintf('%s\n', repmat('-', 1, 58));

        % A voluntary move by an indebted agent should be impossible under the
        % reserve test whenever the move has a cost. If any appear, either the
        % test is not binding as written or distressMode is leaking.
        vDebt = spent & inDebt & ~distress;
        if nnz(vDebt) > 0
            fprintf(2, ['\n%d VOLUNTARY moves were paid for by agents already in debt\n' ...
                        '(total %.4g). The reserve test at choosePortfolio.m:539 should\n' ...
                        'have blocked these. Worth checking before trusting the split.\n'], ...
                    nnz(vDebt), sum(T.moveAccessCost(vDebt)));
        end

        debtShare = 100 * (cell4(inDebt & distress) + cell4(inDebt & ~distress)) / tot;
        fprintf(['\n%.0f%% of all move spending came from agents already at negative\n' ...
                 'wealth.\n'], debtShare);
        if debtShare > 60
            fprintf(['That is the mechanism behind the debt trajectory: mobility is\n' ...
                     'being financed by agents who cannot pay for it, through the one\n' ...
                     'channel that does not check. Each move deepens the deficit that\n' ...
                     'makes the next voluntary move impossible.\n']);
        end
    end

    % How much of the population is locked out of the voluntary channel at any
    % moment -- the arithmetic floor under the trapped fraction.
    fprintf('\nAgent-quarters entering the quarter in debt: %d of %d (%.0f%%).\n', ...
            nnz(inDebt), height(T), 100*nnz(inDebt)/height(T));
    fprintf(['Those agents can only move if the distress trigger fires, whatever\n' ...
             'their preferences -- so this is a lower bound on the trapped fraction\n' ...
             'that owes nothing to behaviour.\n']);
end

% ---------------------------------------------------------------- totals
fprintf('\n=== 5. Decomposition of the total wealth change ===\n');
ch = struct();
ch.income          =  sum(T.netIncome);
ch.subsistence     = -sum(T.subsistNow);
ch.moveAndAccess   = -sum(T.moveAccessCost);
ch.bufferAndBequest=  carryTot;
ch.unexplained     =  sum(T.wealth_resid);

names = fieldnames(ch);
vals  = cellfun(@(n) ch.(n), names);
net   = sum(vals);

% Share of gross OUTFLOW, not of the net change: the net is a small difference
% between large opposing flows, so percentages of it are unstable and can
% exceed 100. Outflow shares answer "what is draining wealth".
outflow = -sum(vals(vals < 0));
fprintf('%-22s %14s %12s\n', 'channel', 'total', '% of drain');
fprintf('%s\n', repmat('-', 1, 50));
for k = 1:numel(names)
    if vals(k) < 0
        fprintf('%-22s %+14.4g %11.1f%%\n', names{k}, vals(k), 100*(-vals(k))/outflow);
    else
        fprintf('%-22s %+14.4g %12s\n', names{k}, vals(k), '(inflow)');
    end
end
fprintf('%s\n', repmat('-', 1, 50));
fprintf('%-22s %+14.4g\n', 'NET', net);

obs = sum(T.wealth_end - T.wealth_preChoice) + carryTot;
fprintf(['\nObserved change over the traced quarters: %+.4g\n' ...
         'Decomposition sums to:                     %+.4g\n'], obs, net);
if abs(obs - net) > tol * max(1, abs(obs))
    fprintf(2, 'These disagree by %.4g -- the decomposition is incomplete.\n', obs - net);
else
    fprintf('They agree, so every channel is accounted for.\n');
end

% ---------------------------------------------------------------- verdict
fprintf('\n=== 6. Verdict ===\n');
drainShare = @(v) 100 * (-v) / max(outflow, eps);
if nRes > 0 || nBad > 0
    fprintf(2, ['Unaccounted arithmetic is present. Treat this as a BUG and fix it\n' ...
                'before drawing any conclusion about structure.\n']);
elseif drainShare(ch.subsistence) > 60
    fprintf(['Subsistence is %.0f%% of the drain. The decline is the accumulated\n' ...
             'consumption deficit, not a defect. Note that subsistence_costs is\n' ...
             'pinned by the food-insecurity target, and food insecurity is DEFINED\n' ...
             'as net income below subsistence -- so the wealth trajectory and the\n' ...
             'FI calibration are the same quantity seen as a stock and as a flow.\n' ...
             'That is a finding to report, not a parameter to retune.\n'], ...
            drainShare(ch.subsistence));
else
    fprintf(['Subsistence is only %.0f%% of the drain, so something else dominates.\n' ...
             'Largest outflow is "%s". This contradicts the expectation that the\n' ...
             'consumption deficit explains the decline -- worth pursuing.\n'], ...
            drainShare(ch.subsistence), names{vals == min(vals)});
end

S = ch; S.net = net; S.observed = obs;
S.nResidual = nRes; S.nIdentityFail = nBad;
end
