function extract_mc_summary(runDir, outCsv)
% extract_mc_summary  --  collapse a set of MC run files into one small CSV
%
%   extract_mc_summary                       % defaults to the current set
%   extract_mc_summary('D:\MIDAS outputs\Set 20 - final calib')
%   extract_mc_summary(runDir, 'mc_summary.csv')
%
% WHY
% The Julia diagnostics (subsistence_vs_fi.jl, fi_decomposition.jl,
% subsistence_target_consistency.jl) each need a handful of scalars per run,
% but MAT.jl's matread pulls the WHOLE file into memory to get them --
% agentSummary, migrationMatrix, countAgentsPerLayer, trappedHistory and
% utilityHistory included. That is hundreds of megabytes decompressed per run
% to extract a few kilobytes, and it is why reading 800 runs takes most of a
% day.
%
% MATLAB reads its own format far faster, and parfor makes the read
% embarrassingly parallel. This extracts every scalar the diagnostics need,
% once, into a CSV that Julia can load in under a second. Re-run it only when
% new MC output appears.
%
% The CSV has one row per run: all sampled parameters (columns named as in the
% input table, dots stripped) plus the derived metrics below.

if nargin < 1 || isempty(runDir)
    % Default to the current calibration set, so the common case is a
    % zero-argument call and the path lives in one place.
    runDir = 'D:\MIDAS outputs\Set 20 - final calib';
    fprintf('No directory given; defaulting to %s\n', runDir);
end
if ~isfolder(runDir)
    error('extract_mc_summary:badDir', 'Directory does not exist: %s', runDir);
end
if nargin < 2 || isempty(outCsv)
    outCsv = fullfile(runDir, 'mc_summary.csv');
end

files = dir(fullfile(runDir, 'MC*.mat'));
if isempty(files)
    error('extract_mc_summary:noFiles', 'No MC*.mat files found in %s', runDir);
end
n = numel(files);
fprintf('Found %d MC files in %s\n', n, runDir);

% Show what is actually in one file, and how much of it we are paying for.
% If a single field dominates, that is worth knowing before optimising further.
fprintf('\nContents of %s:\n', files(1).name);
info = whos('-file', fullfile(files(1).folder, files(1).name));
tot = sum([info.bytes]);
[~, ord] = sort([info.bytes], 'descend');
for k = ord(1:min(6, numel(info)))
    fprintf('   %-28s %8.1f MB\n', info(k).name, info(k).bytes / 1e6);
end
fprintf('   %-28s %8.1f MB total (x %d runs = %.1f GB)\n\n', ...
        '', tot / 1e6, n, tot * n / 1e9);

% Report how the parameter table is actually stored, BEFORE spending the full
% read on it. Getting this wrong once already produced a summary with no
% parameter columns at all, discovered only downstream in Julia.
probe = load(fullfile(files(1).folder, files(1).name), 'input');
if ~isfield(probe, 'input')
    warning('extract_mc_summary:noInput', ...
        ['No "input" variable in %s. Parameter columns will be ABSENT and ' ...
         'the summary will only carry derived metrics.'], files(1).name);
else
    fprintf('Parameter table stored as: %s\n', class(probe.input));
    if istable(probe.input)
        fprintf('   variables: %s\n', strjoin(probe.input.Properties.VariableNames, ', '));
        fprintf('   %d parameters per run\n\n', height(probe.input));
    elseif isstruct(probe.input)
        fprintf('   fields: %s\n\n', strjoin(fieldnames(probe.input)', ', '));
    else
        warning('extract_mc_summary:oddInput', ...
            'Unhandled input class "%s" -- parameter columns may be missing.', ...
            class(probe.input));
    end
end
clear probe;

rows = cell(n, 1);

parfor iF = 1:n
    f = fullfile(files(iF).folder, files(iF).name);
    s = struct();
    s.file = string(files(iF).name);
    try
        % Load ONLY these two variables. Everything else in the file is
        % skipped by the reader rather than decompressed and discarded.
        D = load(f, 'input', 'output');
    catch loadErr
        warning('extract_mc_summary:badFile', 'Skipping %s (%s)', ...
                files(iF).name, loadErr.message);
        rows{iF} = s;
        continue;
    end

    % The saved 'input' is a TABLE in the experiment scripts (see
    % runMIDASExperiment_parallel.m) but a struct in some hand-written run
    % scripts. An earlier version of this file guarded on isstruct alone, so
    % every parameter column was silently dropped and the CSV came out with
    % only the derived metrics. Accept both, and record failure explicitly so
    % it cannot pass unnoticed again.
    s.paramsFound = 0;
    if isfield(D, 'input')
        inp = D.input;
        nm = []; vv = [];
        if istable(inp) && all(ismember({'parameterNames','parameterValues'}, ...
                                        inp.Properties.VariableNames))
            nm = inp.parameterNames;  vv = inp.parameterValues;
        elseif isstruct(inp) && isfield(inp, 'parameterNames')
            nm = inp.parameterNames;  vv = inp.parameterValues;
        end
        if ~isempty(nm)
            for k = 1:numel(nm)
                raw = nm(k);
                if iscell(raw); raw = raw{1}; end
                key = matlab.lang.makeValidName(strrep(string(raw), '.', ''));
                s.(key) = double(vv(k));
            end
            s.paramsFound = numel(nm);
        end
    end

    if isfield(D, 'output') && isstruct(D.output)
        o = D.output;
        g = @(fld) getScalarSum(o, fld);

        agN   = g('agentCount_ag');
        allN  = g('agentCount_all');
        fiAg  = g('foodInsecureCount_ag');
        fiAll = g('foodInsecureCount_all');

        s.agentYears_ag    = agN;
        s.agentYears_all   = allN;
        s.fiCount_ag       = fiAg;
        s.fiCount_all      = fiAll;
        s.foodInsecureRate_ag    = ternary(agN > 0, fiAg / agN, NaN);
        s.foodInsecureRate_all   = ternary(allN > 0, fiAll / allN, NaN);
        s.foodInsecureRate_nonag = ternary(allN > agN, (fiAll - fiAg) / (allN - agN), NaN);
        s.agFrac_nat_run         = ternary(allN > 0, agN / allN, NaN);

        s.migrations_total       = g('migrations');
        s.distressMigrations     = g('distressMigrations');
        s.migrationsPerAgentYear = ternary(allN > 0, g('migrations') / allN, NaN);
        s.distressShare          = ternary(g('migrations') > 0, ...
                                    g('distressMigrations') / g('migrations'), NaN);
    end

    rows{iF} = s;
end

% Union of all field names, so runs with differing fields still line up.
allFields = {};
for k = 1:n
    allFields = union(allFields, fieldnames(rows{k}), 'stable');
end

T = table();
for iFld = 1:numel(allFields)
    fld = allFields{iFld};
    isText = strcmp(fld, 'file');
    if isText
        col = strings(n, 1);
        for k = 1:n
            col(k) = getfielddef(rows{k}, fld, "");
        end
    else
        col = nan(n, 1);
        for k = 1:n
            col(k) = getfielddef(rows{k}, fld, NaN);
        end
    end
    T.(fld) = col;
end

writetable(T, outCsv);
fprintf('Wrote %s  (%d rows x %d columns)\n', outCsv, height(T), width(T));

good = sum(~isnan(T.foodInsecureRate_ag));
fprintf('  usable runs: %d of %d\n', good, n);

% Explicit check that parameters made it through. Without this the CSV looks
% perfectly healthy while being useless for any parameter-vs-metric analysis.
if ismember('paramsFound', T.Properties.VariableNames)
    withParams = sum(T.paramsFound > 0);
    if withParams == 0
        warning('extract_mc_summary:noParams', ...
            ['NO parameter columns were extracted. The summary carries only ' ...
             'derived metrics and cannot support subsistence-vs-target ' ...
             'analysis. Check the "Parameter table stored as:" line above.']);
    else
        fprintf('  runs with parameters: %d of %d (%d parameters each)\n', ...
                withParams, n, max(T.paramsFound));
    end
end
paramCols = setdiff(T.Properties.VariableNames, ...
    {'file','paramsFound','agentYears_ag','agentYears_all','fiCount_ag', ...
     'fiCount_all','foodInsecureRate_ag','foodInsecureRate_all', ...
     'foodInsecureRate_nonag','agFrac_nat_run','migrations_total', ...
     'distressMigrations','migrationsPerAgentYear','distressShare'});
fprintf('  parameter columns: %d\n', numel(paramCols));
if ~isempty(paramCols)
    key = 'agentParameterssubsistence_costs';
    if ismember(key, paramCols)
        fprintf('  %s range [%.3f, %.3f]\n', key, ...
                min(T.(key)), max(T.(key)));
    else
        fprintf(2, '  NOTE: "%s" not among them. First few are: %s\n', ...
                key, strjoin(paramCols(1:min(5, numel(paramCols))), ', '));
    end
end
if good > 0
    fprintf('  foodInsecureRate_ag  median %.4f  (target %.4f)\n', ...
            median(T.foodInsecureRate_ag, 'omitnan'), 3.8/12);
    fprintf('  agFrac_nat_run       median %.4f  (target 0.7600)\n', ...
            median(T.agFrac_nat_run, 'omitnan'));
end
end

% =========================================================================
function v = getScalarSum(o, fld)
% Sum a whole output field to a scalar, tolerating absence and sparsity.
if isfield(o, fld)
    x = full(double(o.(fld)));
    v = sum(x(:), 'omitnan');
else
    v = NaN;
end
end

function out = ternary(cond, a, b)
if cond; out = a; else; out = b; end
end

function v = getfielddef(s, fld, default)
if isfield(s, fld) && ~isempty(s.(fld))
    v = s.(fld);
else
    v = default;
end
end
