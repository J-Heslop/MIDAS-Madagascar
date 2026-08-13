function varargout = agentLifeTrace(action, varargin)
%AGENTLIFETRACE  Per-agent narrative diagnostic for MIDAS-Madagascar.
%
%   Writes two linked CSVs so a modeller can read an agent's life as a
%   story and interrogate any single decision:
%
%     agent_life_history.csv  one row per traced agent-quarter
%     agent_choices.csv       one row per CANDIDATE portfolio evaluated
%
%   The two join on (agentID, t).
%
%   WHY THIS EXISTS
%   Every bug found on 2026-07-28 was invisible at the line level and
%   obvious in aggregate output: vanilla occupancy four times its
%   theoretical ceiling; annualIncome ~0 alongside agIncomeYTD ~6.4;
%   a consumption gap positive in 100% of agent-years. Stepping through
%   the code in a debugger would not have surfaced any of them. This
%   trace is designed so that (a) arithmetic errors appear as non-zero
%   RESIDUAL columns rather than something a reader must notice, and
%   (b) the behavioural narrative can be judged by someone who knows the
%   study system rather than the codebase.
%
%   USAGE (from midasMainLoop / choosePortfolio)
%     agentLifeTrace('init', modelParameters, utilityVariables)
%     tf = agentLifeTrace('isTraced', agentID)
%     agentLifeTrace('register', agentID)        % add to the traced set
%     agentLifeTrace('life',   rowStruct)
%     agentLifeTrace('choice', rowStructArray)
%     agentLifeTrace('flush')                    % write both CSVs
%
%   NB persistent state means this is SINGLE-THREADED ONLY. It is for
%   local diagnostic runs (run_buffer_trace / run_agent_trace), never for
%   the parfor calibration campaign. 'init' is a no-op when
%   modelParameters.traceAgentLife is false or absent, and every other
%   action then returns immediately, so the overhead in production is one
%   function call per traced-agent check.

persistent enabled traceSet lifeRows choiceRows maxAgents traceRegions outDir layerNames

switch lower(action)

    % ------------------------------------------------------------------
    case 'init'
        mp = varargin{1};
        uv = varargin{2};
        enabled = isfield(mp, 'traceAgentLife') && mp.traceAgentLife;
        lifeRows   = {};
        choiceRows = {};
        traceSet   = [];
        if ~enabled; return; end

        maxAgents = 10;
        if isfield(mp, 'traceLifeMaxAgents'); maxAgents = mp.traceLifeMaxAgents; end
        traceRegions = [19 20 21];
        if isfield(mp, 'traceRegions'); traceRegions = mp.traceRegions; end
        outDir = './Outputs/';
        if isfield(mp, 'traceLifeDir'); outDir = mp.traceLifeDir; end
        if ~exist(outDir, 'dir'); mkdir(outDir); end

        % Layer names for the human-readable portfolio string.
        layerNames = strings(1, size(uv.utilityHistory, 2));
        if isfield(mp, 'utilityLayersFile') && exist(mp.utilityLayersFile, 'file')
            LD = readtable(mp.utilityLayersFile, 'TextType', 'string');
            n = min(numel(layerNames), height(LD));
            layerNames(1:n) = string(LD.name(1:n));
        end
        for iL = 1:numel(layerNames)
            if strlength(layerNames(iL)) == 0
                layerNames(iL) = "layer" + iL;
            end
        end
        fprintf(['agentLifeTrace: ENABLED. Following up to %d agents in regions %s.\n' ...
                 '  -> %sagent_life_history.csv and %sagent_choices.csv\n'], ...
                 maxAgents, mat2str(traceRegions), outDir, outDir);

    % ------------------------------------------------------------------
    case 'enabled'
        varargout{1} = ~isempty(enabled) && enabled;

    % ------------------------------------------------------------------
    case 'istraced'
        varargout{1} = ~isempty(enabled) && enabled && ismember(varargin{1}, traceSet);

    % ------------------------------------------------------------------
    case 'register'
        % Add an agent if there is room. Selection is deterministic given
        % the run: the first maxAgents agricultural agents encountered in
        % traceRegions, so the traced set is reproducible across builds.
        varargout{1} = false;
        if isempty(enabled) || ~enabled; return; end
        id = varargin{1};
        if ismember(id, traceSet); varargout{1} = true; return; end
        if numel(traceSet) < maxAgents
            traceSet(end+1) = id; %#ok<AGROW>
            varargout{1} = true;
        end

    % ------------------------------------------------------------------
    case 'regions'
        varargout{1} = traceRegions;

    % ------------------------------------------------------------------
    case 'layerstring'
        % Human-readable portfolio, e.g. "unskilled1|cassava"
        mask = logical(varargin{1});
        nm = layerNames(1:min(numel(mask), numel(layerNames)));
        sel = nm(mask(1:numel(nm)));
        if isempty(sel); varargout{1} = "(none)"; else; varargout{1} = strjoin(sel, "|"); end

    % ------------------------------------------------------------------
    case 'life'
        if isempty(enabled) || ~enabled; return; end
        lifeRows{end+1} = varargin{1}; %#ok<AGROW>

    % ------------------------------------------------------------------
    case 'choice'
        if isempty(enabled) || ~enabled; return; end
        r = varargin{1};
        for k = 1:numel(r)
            choiceRows{end+1} = r(k); %#ok<AGROW>
        end

    % ------------------------------------------------------------------
    case 'flush'
        if isempty(enabled) || ~enabled; return; end
        % A diagnostic writer must never take down a completed run -- a
        % multi-minute simulation was lost to a sparse-array error here on
        % 2026-07-28. Warn and continue instead.
        try
            writeRows(lifeRows,   fullfile(outDir, 'agent_life_history.csv'));
            writeRows(choiceRows, fullfile(outDir, 'agent_choices.csv'));
            fprintf('agentLifeTrace: wrote %d life rows and %d choice rows to %s\n', ...
                    numel(lifeRows), numel(choiceRows), outDir);
        catch wErr
            warning('agentLifeTrace:writeFailed', ...
                ['Trace write FAILED (%s). The simulation itself completed and ' ...
                 'its output is unaffected. Raw rows are in the base workspace ' ...
                 'as agentLifeTraceRaw for recovery.'], wErr.message);
            assignin('base', 'agentLifeTraceRaw', struct('life', {lifeRows}, 'choice', {choiceRows}));
        end

    % ------------------------------------------------------------------
    case 'rewrite'
        % RECOVERY. Write the CSVs from rows salvaged into the base
        % workspace by the flush catch block, without repeating the run:
        %     agentLifeTrace('rewrite', agentLifeTraceRaw, './Outputs/')
        % Deliberately independent of the persistent state, so it works in
        % a fresh MATLAB session after a crash. The 'layers' strings were
        % already resolved when the rows were built, so no layer names are
        % needed here.
        raw = varargin{1};
        dOut = './Outputs/';
        if numel(varargin) >= 2 && ~isempty(varargin{2}); dOut = varargin{2}; end
        if ~exist(dOut, 'dir'); mkdir(dOut); end
        writeRows(raw.life,   fullfile(dOut, 'agent_life_history.csv'));
        writeRows(raw.choice, fullfile(dOut, 'agent_choices.csv'));
        fprintf('agentLifeTrace: recovered %d life rows and %d choice rows to %s\n', ...
                numel(raw.life), numel(raw.choice), dOut);

    otherwise
        error('agentLifeTrace:badAction', 'Unknown action "%s".', action);
end
end

% ======================================================================
function writeRows(rows, fname)
if isempty(rows)
    fprintf('agentLifeTrace: no rows for %s (nothing traced).\n', fname);
    return;
end
% Union of all field names, so rows recorded at different points (e.g.
% quarters with and without the year-end buffer block) still line up.
allFields = {};
for k = 1:numel(rows)
    allFields = union(allFields, fieldnames(rows{k}), 'stable');
end
T = table();
for f = 1:numel(allFields)
    fld = allFields{f};
    col = cell(numel(rows), 1);
    isNum = true;
    for k = 1:numel(rows)
        if isfield(rows{k}, fld)
            v = rows{k}.(fld);
        else
            v = NaN;
        end
        if isstring(v) || ischar(v)
            isNum = false;
        elseif issparse(v)
            v = full(v);          % sparse scalars break cellfun downstream
        end
        col{k} = v;
    end
    if isNum
        % full() is essential: utilityHistory is SPARSE, so any quantity
        % derived from it (income_expect, income_resid) arrives as a sparse
        % scalar, and cellfun rejects those outright. full() is a no-op on
        % ordinary values, so it costs nothing elsewhere.
        T.(fld) = cellfun(@(x) scalarise(x), col);
    else
        % Text column. Rows that lack this field were filled with NaN above,
        % and string(NaN) returns MATLAB's <missing> rather than "NaN" --
        % char(<missing>) then throws, which is what killed a 73-minute run
        % on 2026-08-08 once death rows introduced fields (exitReason,
        % and no layers) that ordinary rows do not carry. Handle the absent
        % case explicitly rather than routing it through string().
        out = strings(numel(col), 1);
        for k = 1:numel(col)
            v = col{k};
            if isstring(v) || ischar(v)
                out(k) = string(v);
            elseif isnumeric(v) && ~isempty(v) && all(isnan(v(:)))
                out(k) = "";            % field absent for this row
            elseif isempty(v)
                out(k) = "";
            else
                out(k) = string(full(v));
            end
        end
        T.(fld) = out;
    end
end
writetable(T, fname);
end

% ======================================================================
function s = scalarise(x)
% Coerce anything that reached a struct field into a plain double scalar:
% sparse -> full, logical -> double, empty -> NaN, array -> first element.
x = full(x);
if isempty(x)
    s = NaN;
else
    s = double(x(1));
end
end
