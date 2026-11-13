function check_truncated_campaign(outDir, paramName)
% CHECK_TRUNCATED_CAMPAIGN  Is the surviving subset of a timed-out campaign usable?
%
%   check_truncated_campaign(outDir)
%   check_truncated_campaign(outDir, 'modelParameters.distressShortfallFrac')
%
% WHY THIS EXISTS
% runMIDASExperiment_parallel saves inside the parfor (one file per iteration),
% so when a job hits its wall clock the files already written survive and the
% rest are lost. The survivors are therefore the FASTEST draws, not a random
% sample of the design. If run time correlates with the parameter being
% identified -- and for a distress threshold it plausibly does, since a lower
% threshold fires more moves and more moves cost time -- then the survivors are
% skewed along exactly the axis being calibrated, and reading a value off them
% gives a biased answer with no warning.
%
% The design is recoverable. experimentList and mcParams are saved BEFORE the
% parfor starts, so the full intended set of draws is on disk even for the runs
% that never completed. That makes this a two-sample question against a known
% counterfactual rather than a guess.
%
% This script answers, in order:
%   1. Was the parameter actually sampled, or pinned to a point?
%   2. Which draws survived?
%   3. Do the survivors span the design, or a truncated part of it?

if nargin < 2 || isempty(paramName)
    paramName = 'modelParameters.distressShortfallFrac';
end
if nargin < 1 || isempty(outDir)
    error('check_truncated_campaign:noDir', 'Pass the campaign output directory.');
end
if ~exist(outDir, 'dir')
    error('check_truncated_campaign:badDir', 'Not a directory: %s', outDir);
end

fprintf('\n=== Truncated-campaign check ===\n');
fprintf('Directory: %s\n', outDir);
fprintf('Parameter: %s\n\n', paramName);

% ---------------------------------------------------------------------------
% 1. THE DESIGN. One input_summary per array task, each holding that task's
%    intended draws. Concatenate to recover the whole campaign.
% ---------------------------------------------------------------------------
summ = dir(fullfile(outDir, 'experiment_*_input_summary.mat'));
if isempty(summ)
    error('check_truncated_campaign:noSummary', ...
          ['No experiment_*_input_summary.mat in %s.\n' ...
           'Without it the intended design is unknown and the survivors ' ...
           'cannot be assessed.'], outDir);
end
fprintf('Found %d input_summary file(s) (one per array task).\n', numel(summ));

designVal  = [];   % sampled value of paramName
designTask = [];
designDraw = [];
boundsSeen = [];

for iS = 1:numel(summ)
    S = load(fullfile(summ(iS).folder, summ(iS).name), ...
             'experimentList', 'mcParams', 'taskId', 'drawIdxList');

    iP = find(strcmp(S.mcParams.Name, paramName), 1);
    if isempty(iP)
        fprintf(['  %s: parameter ABSENT from mcParams. It was never in the ' ...
                 'design.\n'], summ(iS).name);
        continue;
    end
    boundsSeen = [boundsSeen; S.mcParams.Lower(iP), S.mcParams.Upper(iP)]; %#ok<AGROW>

    % One row per unique draw. With nRealisations = 1 slot index == draw index,
    % but read drawIdxList rather than assuming it.
    [~, firstSlot] = unique(S.drawIdxList, 'stable');
    for k = 1:numel(firstSlot)
        e = S.experimentList{firstSlot(k)};
        j = find(strcmp(e.parameterNames, paramName), 1);
        if isempty(j); continue; end
        designVal  = [designVal;  e.parameterValues(j)];      %#ok<AGROW>
        designTask = [designTask; S.taskId];                  %#ok<AGROW>
        designDraw = [designDraw; S.drawIdxList(firstSlot(k))]; %#ok<AGROW>
    end
end

if isempty(designVal)
    error('check_truncated_campaign:notInDesign', ...
          ['%s does not appear in the experiment list.\n' ...
           'Nothing in this campaign varies it, so it cannot be identified ' ...
           'from these runs.'], paramName);
end

lo = min(boundsSeen(:,1)); hi = max(boundsSeen(:,2));
fprintf('Design: %d draws, sampled bounds [%g, %g].\n', numel(designVal), lo, hi);

% ---------------------------------------------------------------------------
% 2. THE PINNED-PARAMETER TRAP. This is the failure that produces a campaign
%    which runs cleanly, costs a day, and identifies nothing. Check it before
%    anything else, and stop here if it fired.
% ---------------------------------------------------------------------------
if hi - lo < eps(max(1, abs(hi)))
    fprintf(2, '\n*** STOP. %s was PINNED at %g. ***\n', paramName, lo);
    fprintf(2, ['Every run used the same value, so these outputs carry no ' ...
                'information\nabout the threshold whatever their number. The ' ...
                'bound needed widening with\n  setMCBounds({''%s'', 0.10, 0.60})\n' ...
                'before submission. Nothing below is worth reading.\n'], paramName);
    return;
end

% ---------------------------------------------------------------------------
% 3. THE SURVIVORS. Filename is MC_Run_T<task>_<slot>_<date>.mat when
%    nRealisations == 1.
% ---------------------------------------------------------------------------
mc = dir(fullfile(outDir, 'MC_Run_*.mat'));
tok = regexp({mc.name}, 'MC_Run_T(\d+)_(\d+)_', 'tokens', 'once');
keep = ~cellfun(@isempty, tok);
mc = mc(keep); tok = tok(keep);
survTask = cellfun(@(t) str2double(t{1}), tok);
survDraw = cellfun(@(t) str2double(t{2}), tok);

if isempty(mc)
    error('check_truncated_campaign:noOutputs', 'No MC_Run_*.mat found in %s.', outDir);
end

isSurv = ismember([designTask designDraw], [survTask(:) survDraw(:)], 'rows');
sv = designVal(isSurv);
fprintf('Survivors: %d of %d draws (%.0f%%).\n', ...
        sum(isSurv), numel(designVal), 100*sum(isSurv)/numel(designVal));

% Reconcile the file count against the matched count. These should be equal.
% A shortfall means MC files exist whose (task, draw) pair is absent from the
% design -- most often files left over from an earlier campaign written into
% the same directory, which would silently contaminate the scatter.
if numel(mc) ~= sum(isSurv)
    fprintf(2, ['  NOTE: %d MC_Run files on disk but only %d matched the ' ...
                'design.\n        The %d unmatched file(s) are not from this ' ...
                'campaign -- check for\n        leftovers from an earlier run ' ...
                'in the same folder before using them.\n'], ...
            numel(mc), sum(isSurv), numel(mc) - sum(isSurv));
end
fprintf('\n');

if sum(isSurv) < 2
    fprintf(2, 'Too few survivors matched to the design to say anything.\n');
    return;
end

% ---------------------------------------------------------------------------
% 4. ARE THE SURVIVORS REPRESENTATIVE? Coverage first -- it is the thing that
%    actually limits what can be claimed -- then a formal test if available.
% ---------------------------------------------------------------------------
q = [0 25 50 75 100];
fprintf('              min     p25     p50     p75     max\n');
fprintf('  design  %7.3f %7.3f %7.3f %7.3f %7.3f\n', prctile(designVal, q));
fprintf('  surviv  %7.3f %7.3f %7.3f %7.3f %7.3f\n', prctile(sv, q));

cover = (max(sv) - min(sv)) / (hi - lo);
fprintf('\nSurvivors cover %.0f%% of the sampled range.\n', 100*cover);

if exist('kstest2', 'file') == 2
    [h, p] = kstest2(sv, designVal);
    if h == 1
        ksNote = '  <-- reject at 5%: survivors differ from the design';
    else
        ksNote = '  (no detectable difference from the design)';
    end
    fprintf('Two-sample KS, survivors vs design: p = %.3f%s\n', p, ksNote);
else
    h = NaN;
    fprintf(['Statistics Toolbox absent -- no KS test. Judge on the quantiles ' ...
             'above.\n']);
end

% Direction of the skew matters more than its significance: a survivor set
% shifted high means the low-threshold end went unsampled, and the low end is
% where the trigger fires often enough to matter.
shift = median(sv) - median(designVal);

fprintf('\n--- Verdict ---\n');
if cover > 0.85 && (isnan(h) || h == 0)
    fprintf(['Survivors span the design and show no detectable skew. Usable for\n' ...
             'direct identification. Report n = %d and state in the methods that\n' ...
             'the campaign was truncated by wall clock and the surviving subset\n' ...
             'was tested against the intended design.\n'], sum(isSurv));
else
    fprintf(2, ['Survivors are NOT representative of the design.\n' ...
                'Median shift %+.3f (%s), range coverage %.0f%%.\n'], ...
            shift, ternary(shift > 0, 'skewed HIGH', 'skewed LOW'), 100*cover);
    fprintf(2, ['Because completion was decided by run time, and run time is not\n' ...
                'independent of this parameter, treat the usable range as\n' ...
                '[%g, %g] only. Do not read a value off the unsampled part, and\n' ...
                'do not describe the subset as a random sample of the prior.\n'], ...
            min(sv), max(sv));
end

% Run time against the parameter is the mechanism. If it slopes, the truncation
% is informative rather than incidental, and that is worth knowing either way.
fprintf('\nTo confirm the mechanism, plot file mtime against the sampled value:\n');
fprintf('  a visible slope means completion was selected ON this parameter.\n');
mt = [mc.datenum]';
mtSurvOrder = zeros(sum(isSurv),1);
idxSurv = find(isSurv);
for k = 1:numel(idxSurv)
    f = find(survTask == designTask(idxSurv(k)) & survDraw == designDraw(idxSurv(k)), 1);
    mtSurvOrder(k) = mt(f);
end
r = corr(sv, mtSurvOrder, 'type', 'Spearman');
fprintf('  Spearman(value, completion time) = %+.2f', r);
if abs(r) > 0.3
    fprintf(2, '   <-- material; the truncation is selecting on this parameter.\n');
else
    fprintf('   (weak)\n');
end
fprintf('\n');
end

function out = ternary(c, a, b)
if c; out = a; else; out = b; end
end
