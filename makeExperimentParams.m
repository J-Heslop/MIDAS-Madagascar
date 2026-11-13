function makeExperimentParams(outDir)
% makeExperimentParams  --  rebuild the mcParams template buildNextRound needs
%
%   makeExperimentParams              % writes into ./Outputs/
%   makeExperimentParams('./Outputs')
%
% WHY THIS EXISTS
% buildNextRound scores every run, then stops before writing the narrowed
% bounds if it cannot find ../Outputs/experiment_*.mat:
%
%     expList = dir('../Outputs/experiment_*.mat');
%     if isempty(expList)
%         warning('No experiment_*.mat ... Cannot update bounds.');
%         return;
%     end
%
% It returns with a WARNING, not an error, so evaluationOutputs.mat is written
% and the summary prints normally -- and it is easy to believe the round
% succeeded when no bounds were produced at all.
%
% That file is normally written by runMIDASExperiment_parallel alongside the
% MC outputs. USE THAT ONE IF YOU CAN FIND IT: copy any
% experiment_*_input_summary.mat from the run directory into ./Outputs/. It
% records the priors the campaign actually sampled from.
%
% This is the fallback for when it is not to hand. buildNextRound uses
% mcParams only for the parameter NAMES and the RoundYN integer flags -- the
% Lower and Upper columns are overwritten by the 5th/95th percentiles of the
% top-scoring runs. So a template rebuilt from the current priors in
% runMIDASExperiment_parallel.m gives the same narrowed result for every
% parameter present in the runs. The one difference: any parameter absent from
% the run outputs keeps the bounds in this template rather than the ones the
% campaign used, so check the printed list against what you expect.

if nargin < 1 || isempty(outDir); outDir = './Outputs'; end
if ~exist(outDir, 'dir'); mkdir(outDir); end

src = 'runMIDASExperiment_parallel.m';
if exist(src, 'file') ~= 2
    error('makeExperimentParams:noSource', ...
        'Run this from the project root -- %s not found here.', src);
end

% Pull the prior definitions straight out of the source, so this cannot drift
% out of step with the design the way a hand-maintained copy would.
txt   = fileread(src);
lines = regexp(txt, '\r\n|\r|\n', 'split');

mcParams = table([], [], [], [], 'VariableNames', {'Name','Lower','Upper','RoundYN'});
nFound = 0;
for k = 1:numel(lines)
    L = strtrim(lines{k});
    if startsWith(L, '%'); continue; end                       % commented out
    tok = regexp(L, ...
        'mcParams\s*=\s*\[mcParams;\s*\{\s*''([^'']+)''\s*,\s*([^,]+),\s*([^,]+),\s*([^}]+)\}\s*\]', ...
        'tokens', 'once');
    if isempty(tok); continue; end
    try
        lo = eval(tok{2});
        hi = eval(tok{3});
        rn = eval(tok{4});
    catch
        fprintf('  skipped (unevaluable): %s\n', L);
        continue;
    end
    mcParams = [mcParams; {tok{1}, lo, hi, rn}]; %#ok<AGROW>
    nFound = nFound + 1;
end

if nFound == 0
    error('makeExperimentParams:noneParsed', ...
        ['Parsed no parameter definitions from %s. The mcParams lines may have ' ...
         'been reformatted; check the regexp against the file.'], src);
end

fprintf('Reconstructed %d parameters from %s\n\n', nFound, src);
fprintf('%-48s %12s %12s %6s\n', 'parameter', 'lower', 'upper', 'int');
for k = 1:height(mcParams)
    fprintf('%-48s %12.5g %12.5g %6d\n', mcParams.Name{k}, ...
            mcParams.Lower(k), mcParams.Upper(k), mcParams.RoundYN(k));
end

% Name it so buildNextRound's dir('experiment_*.mat') glob picks it up, and so
% it is obvious later that it was reconstructed rather than produced by a run.
fname = fullfile(outDir, ...
    ['experiment_' datestr(now, 'dd-mmm-yyyy') '_RECONSTRUCTED_input_summary.mat']);
save(fname, 'mcParams');
fprintf('\nWrote %s\n', fname);
fprintf(['\nNow re-run buildNextRound. It must print\n' ...
         '  "Saved updatedMCParams.mat with narrowed bounds for next calibration round."\n' ...
         'If that line does not appear, the bounds were still not written.\n']);
end
