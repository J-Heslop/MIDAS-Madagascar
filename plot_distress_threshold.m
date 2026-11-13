function T = plot_distress_threshold(runDir, varargin)
% PLOT_DISTRESS_THRESHOLD  Identify distressShortfallFrac against the kere contrast.
%
%   T = plot_distress_threshold('D:\MIDAS outputs\Set 24 - testing')
%   T = plot_distress_threshold(runDir, 'Refresh', true)
%
% WHAT IT PLOTS
% Grand Sud (Androy, Anosy, Atsimo-Andrefana) out-migration per agent-year
% against the sampled modelParameters.distressShortfallFrac, split into
% forced (distress-triggered) and voluntary moves, and within each into
% drought-associated kere years, ordinary years, and the two famine years
% that carry neutral-to-positive SPEI.
%
% Forced and voluntary partition the total exactly: voluntary is
% outMigrations - distressMigrations. Both are top-level fields of every
% calibration output, so nothing here needs AGENT_TRACE=1. consideredHistory
% is gated behind that flag and is absent from these runs, but it is not
% required -- "considered" in the drought-response figure means the voluntary
% partition, not the set of portfolios an agent evaluated.
%
% THE TARGET
% Observed kere-year displacement is of the order 2-4% of Grand Sud agents
% making a distress move, against close to zero in ordinary years. The
% quantity to read off is the CONTRAST, not either level alone: baseline
% Grand Sud mobility is seasonal labour migration to Alaotra and Marovoay,
% which the distress channel should not be reproducing. The two famine years
% with neutral SPEI (2002, 2013) are a negative control -- a threshold that
% lights those up as brightly as the drought kere years is responding to
% something other than drought.
%
% If no value of the threshold satisfies both sides of the contrast, that is
% itself the finding, and it is the one the campaign was designed to be able
% to return: the trigger cannot reproduce the observed concentration and the
% threshold is the wrong instrument.
%
% CAVEAT ON n
% The campaign was truncated by wall clock. Roughly 29 of 100 draws survive,
% and the other ~76 parameters are still sampling underneath, so the scatter
% is noisy by construction. Fit a trend across it and take a RANGE. Do not
% read a value off the nearest single point.

% ---------------------------------------------------------------- arguments
p = inputParser;
p.addRequired('runDir',  @(x) ischar(x) || isstring(x));
p.addParameter('Refresh', false, @islogical);
p.addParameter('CsvName', 'distress_threshold_summary.csv', @(x) ischar(x) || isstring(x));
p.addParameter('PngName', 'fig_distress_threshold.png', @(x) ischar(x) || isstring(x));
% Restrict to runs whose drought scale factor falls in the range identified
% from documented yield losses (see calibrate_drought_scale.m). Runs outside
% it are not wrong, but they describe a crop response the literature does not
% support, and including them widens every spread shown here.
p.addParameter('AlphaMin', [], @(x) isempty(x) || isnumeric(x));
p.addParameter('AlphaMax', [], @(x) isempty(x) || isnumeric(x));
p.parse(runDir, varargin{:});
opt = p.Results;
runDir = char(opt.runDir);

if ~isfolder(runDir)
    error('plot_distress_threshold:badDir', 'Directory does not exist: %s', runDir);
end
csvPath = fullfile(runDir, char(opt.CsvName));
pngPath = fullfile(runDir, char(opt.PngName));

% ---------------------------------------------------------------- constants
% Model (shapefile) region order, per buildNextRound.m. The Grand Sud indices
% are asserted against these names rather than hard-coded blind: the whole
% region-naming episode came from trusting an index that had silently moved.
REGION_NAMES = { ...
    'Analamanga','Bongolava','Itasy','Vakinankaratra', ...
    'Diana','Sava','Amoroni_Mania','Atsimo_Atsinanana', ...
    'Haute_Matsiatra','Ihorombe','Vatovavy_Fitovinany','Betsiboka', ...
    'Boeny','Melaky','Sofia','Alaotra_Mangoro', ...
    'Analanjirofo','Atsinanana','Androy','Anosy', ...
    'Atsimo_Andrefana','Menabe'};
GRAND_SUD  = [19 20 21];
assert(isequal(REGION_NAMES(GRAND_SUD), ...
               {'Androy','Anosy','Atsimo_Andrefana'}), ...
       'Grand Sud indices do not match the expected region names.');

START_YEAR   = 1985;
CYCLE_LENGTH = 4;
% NO END_YEAR CONSTANT. drought_response_panels.jl hard-codes 2085 because it
% was written for projection output, and copying that here skipped all 29
% files: these are calibration runs to 2025, so numCycles came out 100 instead
% of 40 and nValid was computed as 99 against 40 correct annual columns.
% readParameters.m:675 gives timeSteps = spinupTime + numCycles*cycleLength,
% and spinupTime is in each run's own input table, so the horizon is derived
% per run instead. That makes this work on either horizon without a flag.

% Drought-associated kere years, per drought_migration_comparison.jl. 1997 is
% held separately: under the corrected cassava sampling window it carries a
% slightly POSITIVE perturbation, so it may not be a drought-driven event at
% all, and the kere rate is reported both with and without it.
KERE_DROUGHT = [1991 1992 2016 2017 2018 2021];
KERE_QUERY   = 1997;
KERE_FAMINE  = [2002 2013];   % negative control: famine, neutral-to-positive SPEI

PARAM = 'modelParameters.distressShortfallFrac';

% ---------------------------------------------------------------- extraction
needCols = {'thresholdAbs','subsistenceCosts','forced_kere','fi_nat','fi_gs', ...
            'forced_perWA','fi_all_gs','distressOverFI','droughtScale'};
useCache = exist(csvPath, 'file') && ~opt.Refresh;
if useCache
    T = readSummaryCsv(csvPath);
    % A cache written by an older version of this file will be missing columns
    % added since. Re-extract rather than erroring on a missing variable, which
    % reads as a bug in the analysis rather than a stale file.
    missingCols = setdiff(needCols, T.Properties.VariableNames);
    if ~isempty(missingCols)
        fprintf('Cached summary predates columns: %s -- re-extracting.\n', ...
                strjoin(missingCols, ', '));
        useCache = false;
    end
end
if useCache
    fprintf('Reading cached summary: %s\n', csvPath);
    fprintf('(pass ''Refresh'', true to re-read the .mat files)\n\n');
else
    T = extractRuns(runDir, GRAND_SUD, START_YEAR, CYCLE_LENGTH, ...
                    PARAM, KERE_DROUGHT, KERE_QUERY, KERE_FAMINE);
    writetable(T, csvPath);
    fprintf('\nWrote %s (%d runs).\n', csvPath, height(T));
end

T = applyAlphaFilter(T, opt.AlphaMin, opt.AlphaMax);
T = T(~isnan(T.threshold) & ~isnan(T.thresholdAbs), :);
if height(T) < 3
    error('plot_distress_threshold:tooFew', ...
          ['Only %d runs carry a sampled %s. Nothing to fit.'], height(T), PARAM);
end
if range(T.threshold) < 1e-9
    error('plot_distress_threshold:pinned', ...
          ['%s is constant at %g across every run. It was pinned rather than ' ...
           'sampled, so these outputs cannot identify it.'], PARAM, T.threshold(1));
end

% How badly does the nominal fraction misrepresent the real trigger level?
% If subsistence_costs varies materially, the two axes are not monotone in one
% another and the nominal one cannot identify anything.
rhoAx = corr(T.threshold, T.thresholdAbs, 'type', 'Spearman', 'rows', 'complete');
fprintf(['subsistence_costs across runs: %.2f to %.2f (x%.1f).\n' ...
         'Absolute trigger level = frac x 4 x subsistence_costs spans %.2f to %.2f.\n' ...
         'Spearman(nominal frac, absolute level) = %+.2f.\n'], ...
        min(T.subsistenceCosts), max(T.subsistenceCosts), ...
        max(T.subsistenceCosts)/max(min(T.subsistenceCosts), eps), ...
        min(T.thresholdAbs), max(T.thresholdAbs), rhoAx);
if rhoAx < 0.9
    fprintf(2, ['The two axes disagree. Plotting against the nominal fraction ' ...
                'reorders the runs\nwith respect to what actually gates the ' ...
                'trigger -- which is what flattened the\nfirst version of ' ...
                'this figure.\n']);
end
fprintf('\n');

% ---------------------------------------------------------------- the figure
% Plot against the ABSOLUTE trigger level, not the nominal fraction. This is
% the food-equivalent shortfall an agent must exceed before the trigger can
% fire, and it is the quantity checkDistressTrigger case 6 actually tests.
X = T.thresholdAbs;

f = figure('Color', 'w', 'Position', [100 100 1020 460]);
tl = tiledlayout(f, 1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

pal = [0.78 0.24 0.20;    % kere (drought)
       0.30 0.45 0.70;    % ordinary years
       0.45 0.45 0.45;    % famine control
       0.85 0.55 0.10];   % 1997, held separate

series = { ...
    'forced',    {'forced_kere','forced_ordinary','forced_famine','forced_1997'}, ...
                 'Forced (distress-triggered) moves'; ...
    'voluntary', {'vol_kere','vol_ordinary','vol_famine','vol_1997'}, ...
                 'Voluntary moves (total minus forced)'};

labels = {'kere years, drought-associated (n=6)', ...
          'ordinary years', ...
          'kere years, neutral SPEI (2002, 2013)', ...
          '1997 (positive perturbation under corrected index)'};

for iS = 1:size(series, 1)
    ax = nexttile(tl); hold(ax, 'on'); box(ax, 'on');
    cols = series{iS, 2};
    h = gobjects(0); lg = {};

    % Target band, drawn first so points sit on top of it. Only meaningful on
    % the forced panel -- the 2-4% figure is a distress-displacement estimate.
    if strcmp(series{iS,1}, 'forced')
        xl = [min(X) max(X)];
        hb = patch(ax, [xl fliplr(xl)], [2 2 4 4], [0.20 0.60 0.35], ...
                   'FaceAlpha', 0.10, 'EdgeColor', 'none');
        h(end+1) = hb; lg{end+1} = 'observed kere displacement, 2-4%'; %#ok<AGROW>
    end

    for k = 1:numel(cols)
        y = T.(cols{k});
        hs = scatter(ax, X, y, 26, pal(k,:), 'filled', ...
                     'MarkerFaceAlpha', 0.75);
        h(end+1) = hs; lg{end+1} = labels{k}; %#ok<AGROW>

        % Binned median rather than a line fit: with ~29 points and 76 other
        % parameters live, a least-squares slope implies a precision the data
        % does not have. Bins show the trend without asserting a functional form.
        [bx, by] = binnedMedian(X, y, 5);
        ok = ~isnan(by);
        if nnz(ok) >= 2
            hl = plot(ax, bx(ok), by(ok), '-', 'Color', pal(k,:), 'LineWidth', 1.6);
            if k == 1
                h(end+1) = hl; lg{end+1} = 'binned median (same colour as points)'; %#ok<AGROW>
            end
        end
    end

    xlabel(ax, {'distress trigger level (food-equivalent units)', 'distressShortfallFrac x 4 x subsistence\_costs'});
    ylabel(ax, 'Grand Sud moves per 100 person-years');
    title(ax, series{iS, 3}, 'FontWeight', 'normal');
    grid(ax, 'on'); ax.GridAlpha = 0.12;

    % ONE legend for the figure, docked south. Two per-axis 'northoutside'
    % legends in a tiledlayout overlap each other and render as garbled
    % duplicates -- which is what made the first version unreadable.
    if iS == 1
        lgd = legend(ax, h, lg, 'FontSize', 8, 'Box', 'off', 'NumColumns', 3);
        lgd.Layout.Tile = 'south';
    end
end

title(tl, sprintf(['Grand Sud out-migration per agent-year against sampled ' ...
                   'distress threshold (%d runs, %s)'], ...
                  height(T), strrep(char(runDir), '\', '/')), ...
      'FontWeight', 'bold', 'FontSize', 10, 'Interpreter', 'none');

exportgraphics(f, pngPath, 'Resolution', 200);
fprintf('Wrote %s\n', pngPath);

% ---------------------------------------------------------------- the readout
fprintf('\n=== Contrast against the threshold ===\n');
fprintf('%11s  %5s  %9s  %9s  %8s\n', ...
        'trig level', 'n', 'kere', 'ordinary', 'ratio');
edges = linspace(min(X), max(X), 6);
for b = 1:numel(edges)-1
    if b == numel(edges)-1
        m = X >= edges(b) & X <= edges(b+1);
    else
        m = X >= edges(b) & X < edges(b+1);
    end
    if ~any(m); continue; end
    kk = median(T.forced_kere(m), 'omitnan');
    oo = median(T.forced_ordinary(m), 'omitnan');
    fprintf('%5.2f-%5.2f  %5d  %9.3f  %9.3f  %8s\n', ...
            edges(b), edges(b+1), nnz(m), kk, oo, ...
            ternaryStr(oo > 0, sprintf('%.2f', kk/max(oo,eps)), 'inf'));
end

% CONSISTENCY CEILING. Report before anything interpretive: if this is
% violated the rest of the figure is describing a broken mechanism.
if ismember('distressOverFI', T.Properties.VariableNames) && any(~isnan(T.distressOverFI))
    r = T.distressOverFI(~isnan(T.distressOverFI));
    fprintf(['\nGrand Sud, observed window: distress moves %.3f per working-age ' ...
             'agent-year\nagainst a food-insecure share of %.3f -- ratio %.2f ' ...
             '(range %.2f-%.2f over %d runs).\n'], ...
            median(T.forced_perWA,'omitnan'), median(T.fi_all_gs,'omitnan'), ...
            median(r), min(r), max(r), numel(r));
    if max(r) > 1.02
        fprintf(2, ['\n*** IDENTITY VIOLATED in %d of %d runs. ***\n' ...
                    'A distress move requires lastShortfall > threshold > 0, ' ...
                    'which is the same\ncondition that marks an agent food-' ...
                    'insecure, and the 4-quarter cooldown caps\nfiring at once ' ...
                    'per agent-year. The ratio cannot exceed 1. Agents are ' ...
                    'moving\nunder the distress flag without a qualifying ' ...
                    'shortfall -- find that before\ntuning anything else.\n'], ...
                nnz(r > 1.02), numel(r));
    else
        fprintf(['Ceiling respected (<= 1), so firing is genuinely a subset of ' ...
                 'food insecurity.\nAt a ratio near %.2f the trigger is ' ...
                 'selecting %.0f%% of food-insecure agent-years.\n'], ...
                median(r), 100*median(r));
    end
end

% Alignment first: if the calendar mapping is wrong, everything above is
% measured on the wrong years and the contrast is meaningless.
if ismember('kereOverlap', T.Properties.VariableNames) && any(~isnan(T.kereOverlap))
    ov = median(T.kereOverlap, 'omitnan');
    fprintf(['\nCalendar alignment: %.0f%% of model-flagged Grand Sud drought ' ...
             'years fall in the kere list.\n'], 100*ov);
    if ov < 0.35
        fprintf(2, ['This is low. The year mapping (years = %d + 1:nValid) may ' ...
                    'be offset, in which\ncase the contrast is being measured ' ...
                    'on the wrong years. Check before reading\nanything off ' ...
                    'the figure.\n'], 1985);
    end
else
    fprintf(['\nCalendar alignment: droughtStates absent, so the year mapping ' ...
             'is unverified.\n']);
end

% The contrast, not either level, is the calibration target -- so report how
% the RATIO moves, and whether it was still moving at the top of the sweep.
% A ratio still climbing at the highest sampled threshold means the prior was
% too narrow, which is a different conclusion from "the threshold does nothing".
ratios = nan(numel(edges)-1, 1); mids = nan(size(ratios));
for b = 1:numel(edges)-1
    if b == numel(edges)-1; m = X >= edges(b) & X <= edges(b+1);
    else;                   m = X >= edges(b) & X <  edges(b+1); end
    if ~any(m); continue; end
    oo = median(T.forced_ordinary(m), 'omitnan');
    if oo > 0
        ratios(b) = median(T.forced_kere(m), 'omitnan') / oo;
        mids(b)   = mean(edges(b:b+1));
    end
end
ok = ~isnan(ratios);
if nnz(ok) >= 3
    rhoR = corr(mids(ok), ratios(ok), 'type', 'Spearman');
    fprintf(['\nkere:ordinary contrast rises from %.2f to %.2f across the sweep ' ...
             '(Spearman %+.2f).\n'], ratios(find(ok,1)), ratios(find(ok,1,'last')), rhoR);
    if rhoR > 0.5 && ratios(find(ok,1,'last')) == max(ratios(ok))
        fprintf(2, ['The contrast is still INCREASING at the highest threshold ' ...
                    'sampled (%.2f).\nThe prior stopped before the response ' ...
                    'turned over, so the identifying range\nlies above it -- ' ...
                    'widen the bound rather than reading a value off this.\n'], ...
                max(X));
    end
end

rho = corr(X, T.forced_kere, 'type', 'Spearman', 'rows', 'complete');
fprintf('\nSpearman(trigger level, forced kere rate) = %+.2f\n', rho);
if abs(rho) < 0.3
    fprintf(2, ['The threshold barely moves the forced kere rate across the ' ...
                'sampled range.\nIf that holds, the constraint is upstream of ' ...
                'the trigger and no value of this\nparameter will reproduce ' ...
                'the observed concentration -- report that rather than\n' ...
                'picking a number off a flat scatter.\n']);
end
end

% =========================================================================
function T = extractRuns(runDir, gs, startYear, cyc, ...
                         param, kereD, kereQ, kereF)
% One pass over the MC files. Each carries its own `input` table, so the
% sampled parameter comes from the file itself rather than from a separate
% input_summary that may or may not correspond to it.

files = dir(fullfile(runDir, 'MC*.mat'));
if isempty(files)
    error('plot_distress_threshold:noFiles', 'No MC*.mat in %s', runDir);
end
n = numel(files);
fprintf('Reading %d MC files from %s\n', n, runDir);
fprintf('(each is a few hundred MB; this is the slow step, and it is cached)\n');

rows = cell(n, 1);
parfor iF = 1:n
    fp = fullfile(files(iF).folder, files(iF).name);
    s = struct('file', string(files(iF).name), 'threshold', NaN);
    try
        D = load(fp, 'input', 'output');
    catch err
        warning('plot_distress_threshold:badFile', 'Skipping %s (%s)', ...
                files(iF).name, err.message);
        rows{iF} = s; continue;
    end

    % --- sampled parameters ---------------------------------------------
    % spinupTime is pinned rather than varied, but read it from the run rather
    % than assuming 10: it sets the whole year alignment below, and a silent
    % change to it would shift every year by one without any other symptom.
    spinupTime = NaN; subsCosts = NaN; droughtScale = NaN;
    if isfield(D, 'input')
        inp = D.input; nm = []; vv = [];
        if istable(inp) && all(ismember({'parameterNames','parameterValues'}, ...
                                         inp.Properties.VariableNames))
            nm = inp.parameterNames; vv = inp.parameterValues;
        elseif isstruct(inp) && isfield(inp, 'parameterNames')
            nm = inp.parameterNames; vv = inp.parameterValues;
        end
        for k = 1:numel(nm)
            raw = nm(k); if iscell(raw); raw = raw{1}; end
            switch char(raw)
                case param;                          s.threshold = double(vv(k));
                case 'modelParameters.spinupTime';   spinupTime  = double(vv(k));
                case 'agentParameters.subsistence_costs'
                                                     subsCosts   = double(vv(k));
                case 'modelParameters.droughtScaleFactor'
                                                     droughtScale = double(vv(k));
            end
        end
    end

    if ~isfield(D, 'output') || ~isstruct(D.output)
        rows{iF} = s; continue;
    end
    o = D.output;
    % isfield takes a cell array and returns a logical per name, so no loop is
    % needed. parfor forbids indexing a for-loop variable, and a `continue`
    % inside such a loop would in any case have skipped to the next FIELD
    % rather than the next file, processing the run with the field missing.
    % agentCount_pop, NOT agentCount_all. midasMainLoop.m:1636 spells this out:
    % agentCount_all is a WORKING-AGE series (age >= ageDecision), whereas
    % migration counts are all-ages events, and dividing one by the other
    % "would shrink the model denominator by roughly the under-15 share and
    % bias every level-based migration error metric, silently". With an
    % under-15 share near 40% that inflates every rate by about 1.7x.
    reqFields = {'outMigrations','distressMigrations','agentCount_pop'};
    have = isfield(o, reqFields);
    if ~all(have)
        warning('plot_distress_threshold:missingField', ...
                '%s: missing %s -- skipped', files(iF).name, ...
                strjoin(reqFields(~have), ', '));
        rows{iF} = s; continue;
    end

    % --- geometry -------------------------------------------------------
    % timeSteps = spinupTime + numCycles*cycleLength (readParameters.m:675),
    % so with spinupTime known the horizon follows from the array width and
    % nothing about the end year need be assumed. Annual arrays now carry one
    % column per model year with no spinup columns and no trimming, so nValid
    % is simply numCycles. Runs produced before 2026-09-11 have the old layout
    % (sized on a t=1 grid, then trimmed) and are NOT readable by this script.
    out = o.outMigrations; dis = o.distressMigrations;
    nT  = size(out, 2);
    if isnan(spinupTime)
        warning('plot_distress_threshold:noSpinup', ...
                '%s: modelParameters.spinupTime absent from input; assuming 10.', ...
                files(iF).name);
        spinupTime = 10;
    end
    numCycles   = (nT - spinupTime) / cyc;
    if abs(numCycles - round(numCycles)) > 1e-9 || numCycles < 1
        warning('plot_distress_threshold:geometry', ...
                ['%s: %d timesteps with spinupTime %g gives a non-integer ' ...
                 'number of cycles (%.3f) -- skipped.'], ...
                files(iF).name, nT, spinupTime, numCycles);
        rows{iF} = s; continue;
    end
    % MODEL-YEAR GRID (updated 2026-09-11, must move with midasMainLoop).
    %
    % Model year y occupies timesteps spinupTime + (y-1)*cyc + 1 .. spinupTime
    % + y*cyc and IS calendar year startYear + y - 1, as laid out by
    % createUtilityLayers.m:750. The annual arrays from midasMainLoop now carry
    % exactly one column per model year on that grid, with no spinup columns.
    %
    % This previously read
    %     spinupYears = ceil(spinupTime / cyc);       % 3
    %     nValid      = floor(nT / cyc) - spinupYears;
    %     years       = startYear + (1:nValid);
    % which matched the old output layout: arrays sized on a t=1 grid, then
    % stripped of ceil(spinupTime/cyc) columns. Both of those are gone, so the
    % old arithmetic would now drop three real model years and mislabel the
    % rest by a year. Keeping the two files in step is not optional.
    nValid = numCycles;
    years  = startYear + (0:nValid-1);

    nAll = o.agentCount_pop;
    if size(nAll, 2) < nValid
        warning('plot_distress_threshold:geometry', ...
                ['%s: agentCount_pop has %d columns, expected >= %d. ' ...
                 'Geometry assumption broken -- skipped.'], ...
                files(iF).name, size(nAll, 2), nValid);
        rows{iF} = s; continue;
    end

    totA = quarterlyToAnnual(out, spinupTime, nValid, cyc);
    forA = quarterlyToAnnual(dis, spinupTime, nValid, cyc);
    volA = totA - forA;
    denom = double(nAll(:, 1:nValid));

    % --- Grand Sud, per year -------------------------------------------
    % Pooled across the three regions: sum moves, sum agent-years, then divide.
    % Averaging three regional rates would weight Androy equally with
    % Atsimo-Andrefana, which is over half the Grand Sud population.
    fGS = sum(forA(gs, :), 1);
    vGS = sum(volA(gs, :), 1);
    dGS = sum(denom(gs, :), 1);

    rate = @(num, mask) 100 * sum(num(mask)) / max(sum(dGS(mask)), eps);

    mK = ismember(years, kereD);
    mQ = ismember(years, kereQ);
    mF = ismember(years, kereF);
    mO = ~(mK | mQ | mF) & years <= 2022;   % ordinary OBSERVED years only

    % CALENDAR ALIGNMENT CHECK. years = startYear + (1:nValid) is the
    % convention in drought_response_panels.jl, but that figure aligned on the
    % model's own drought flags in event time, so a calendar offset would never
    % have shown up in it. Here the kere years ARE calendar years, so an
    % off-by-one moves the entire contrast onto the wrong years.
    %
    % Test it rather than assume it: the model's droughtStates for the Grand
    % Sud should concentrate in the years the record calls kere. High overlap
    % means the mapping is right; low overlap means it is shifted and every
    % number below is measured on the wrong years.
    % DO NOT use outputs.droughtStates for this. createUtilityLayers fills
    % droughtStates for EVERY year 1:nSimYears from the Markov chain (line
    % ~592-608), but only APPLIES it as a yield perturbation from firstProjCyc
    % onward (line ~708). So over the observation window it is a synthetic
    % sequence that was never used, uncorrelated with the observed record --
    % and comparing kere years against it returns the base rate (7/39 = 18%)
    % and looks exactly like a calendar offset. It is not one.
    %
    % Left NaN rather than deleted: the column documents why the obvious check
    % is invalid, so it does not get reinvented.
    s.kereOverlap = NaN;

    % THE QUANTITY THE TRIGGER ACTUALLY USES.
    % midasMainLoop.m:149 sets distressShortfallAbs = distressShortfallFrac *
    % annualSubsist, and annualSubsist = cycleLength * subsistence_costs
    % (line 132). subsistence_costs is NOT pinned in this campaign -- it is one
    % of the 76 parameters still sampling -- so equal values of frac do NOT
    % mean equal trigger levels. Plotting against frac alone reorders the runs
    % at random with respect to the thing that gates firing, which is what
    % flattened the first version of this figure.
    s.droughtScale     = droughtScale;
    s.subsistenceCosts = subsCosts;
    s.annualSubsist    = cyc * subsCosts;
    s.thresholdAbs     = s.threshold * cyc * subsCosts;

    % --- FOOD INSECURITY, on buildNextRound's own terms -----------------
    % foodInsecureTarget_agFrac = 3.8/12 = 0.317 of working-age AGRICULTURAL
    % agent-years (buildNextRound.m:176), measured from FI_BURNIN_YEAR = 2000
    % (line 194) to the 2018 census year. Reproduce that window exactly --
    % scoring FI over a different span would confound "subsistence is wrong"
    % with "the window moved", which is the whole point of checking it.
    if isfield(o, 'foodInsecureCount_ag') && isfield(o, 'agentCount_ag')
        fi = double(o.foodInsecureCount_ag); na = double(o.agentCount_ag);
        wFI = min([size(fi,2), size(na,2), nValid]);
        mFI = years(1:wFI) >= 2000 & years(1:wFI) <= 2018;
        num = sum(sum(fi(:, 1:wFI) .* mFI));  den = sum(sum(na(:, 1:wFI) .* mFI));
        s.fi_nat = num / max(den, eps);
        s.fi_gs  = sum(sum(fi(gs, 1:wFI) .* mFI)) / ...
                   max(sum(sum(na(gs, 1:wFI) .* mFI)), eps);
        s.agentYears_ag_nat = den;
    else
        s.fi_nat = NaN; s.fi_gs = NaN; s.agentYears_ag_nat = NaN;
    end

    % --- HARD CONSISTENCY CHECK ----------------------------------------
    % checkDistressTrigger case 6 fires only when lastShortfall > sfThresh,
    % and sfThresh > 0 whenever distressShortfallFrac > 0. lastShortfall > 0
    % is also exactly the condition that sets wasInsecure (midasMainLoop.m
    % ~1580). The cooldown is 4 quarters, so an agent can fire at most once
    % per year. Therefore, over the same population and window:
    %
    %     distress moves per working-age agent-year  <=  food-insecure share
    %
    % This is an identity, not a modelling expectation. A ratio above 1 means
    % agents are moving under the distress flag without a qualifying
    % shortfall, and no amount of re-tuning bounds will fix that.
    s.forced_perWA = NaN; s.fi_all_gs = NaN; s.distressOverFI = NaN;
    if isfield(o, 'foodInsecureCount_all') && isfield(o, 'agentCount_all')
        fiA = double(o.foodInsecureCount_all); naA = double(o.agentCount_all);
        w2  = min([size(fiA,2), size(naA,2), nValid]);
        m2  = years(1:w2) <= 2022;                      % observed window
        waDen = sum(sum(naA(gs, 1:w2) .* m2));          % working-age agent-years
        if waDen > 0
            s.forced_perWA  = sum(fGS(1:w2) .* m2) / waDen;
            s.fi_all_gs     = sum(sum(fiA(gs, 1:w2) .* m2)) / waDen;
            if s.fi_all_gs > 0
                s.distressOverFI = s.forced_perWA / s.fi_all_gs;
            end
        end
    end

    s.endYear        = startYear + numCycles;
    s.nValidYears    = nValid;
    s.forced_kere    = rate(fGS, mK);
    s.forced_1997    = rate(fGS, mQ);
    s.forced_famine  = rate(fGS, mF);
    s.forced_ordinary= rate(fGS, mO);
    s.vol_kere       = rate(vGS, mK);
    s.vol_1997       = rate(vGS, mQ);
    s.vol_famine     = rate(vGS, mF);
    s.vol_ordinary   = rate(vGS, mO);
    s.forced_kereQ   = rate(fGS, mK | mQ);   % kere rate WITH 1997 included
    s.agentYears_gs  = sum(dGS(mK | mO | mF | mQ));

    rows{iF} = s;
end

flds = {};
for k = 1:n; flds = union(flds, fieldnames(rows{k}), 'stable'); end
T = table();
for iFld = 1:numel(flds)
    fld = flds{iFld};
    if strcmp(fld, 'file')
        col = strings(n,1);
        for k = 1:n; col(k) = getdef(rows{k}, fld, ""); end
    else
        col = nan(n,1);
        for k = 1:n; col(k) = getdef(rows{k}, fld, NaN); end
    end
    T.(fld) = col;
end
end

% =========================================================================
function A = quarterlyToAnnual(Q, spinupTime, nValid, cyc)
% Bin a quarterly series onto the model year grid (updated 2026-09-11).
%
% Model year k is quarters spinupTime + (k-1)*cyc + 1 .. spinupTime + k*cyc,
% matching createUtilityLayers.m:750 and midasMainLoop's annual arrays.
%
% PREVIOUS BEHAVIOUR, and why it changed. This used to take spinupYears =
% ceil(spinupTime/cyc) and bin from (spinupYears+k-1)*cyc+1, to match the
% annual arrays as midasMainLoop then produced them -- sized on a grid
% anchored at t = 1 and trimmed by whole years. Because spinupTime = 10 is
% not a multiple of cycleLength = 4, that grid sat two quarters from the
% yield data, so every bin held two quarters of one drought year and two of
% the next. Aligning the numerator to it made the numerator, denominator and
% drought signal mutually consistent, but left that half-year straddle in all
% of them: each drought was split across two adjacent bins, halving its
% apparent magnitude.
%
% midasMainLoop now writes its annual arrays on the model-year grid directly,
% so the straddle is gone and this bins on the same grid rather than
% compensating for a different one.
A = zeros(size(Q,1), nValid);
for k = 1:nValid
    t0 = spinupTime + (k-1)*cyc + 1;
    t1 = spinupTime + k*cyc;
    if t0 > size(Q,2); break; end
    A(:,k) = sum(Q(:, t0:min(t1, size(Q,2))), 2);
end
end

function [bx, by] = binnedMedian(x, y, nb)
edges = linspace(min(x), max(x), nb+1);
bx = nan(nb,1); by = nan(nb,1);
for b = 1:nb
    if b == nb; m = x >= edges(b) & x <= edges(b+1);
    else;       m = x >= edges(b) & x <  edges(b+1); end
    if any(m); bx(b) = median(x(m)); by(b) = median(y(m), 'omitnan'); end
end
end

function v = getdef(s, f, d)
if isfield(s, f) && ~isempty(s.(f)); v = s.(f); else; v = d; end
end

function s = ternaryStr(c, a, b)
if c; s = a; else; s = b; end
end


% =========================================================================
function T = applyAlphaFilter(T, aMin, aMax)
% Restrict an already-extracted table to a droughtScaleFactor range, and say
% plainly what was dropped. Silently discarding two thirds of an ensemble is
% how a filtered result gets mistaken for the whole one.
if isempty(aMin) && isempty(aMax); return; end
if ~ismember('droughtScale', T.Properties.VariableNames)
    error('applyAlphaFilter:noColumn', ...
          ['The cached summary predates the droughtScale column. Re-run with ' ...
           '''Refresh'', true before filtering.']);
end
n0 = height(T);
keep = true(n0,1);
if ~isempty(aMin); keep = keep & T.droughtScale >= aMin; end
if ~isempty(aMax); keep = keep & T.droughtScale <= aMax; end
T = T(keep,:);
fprintf(['Filtered to droughtScaleFactor in [%s, %s]: %d of %d runs retained ' ...
         '(%.0f%%).\n'], ...
        ternaryStr(isempty(aMin),'-inf',num2str(aMin)), ...
        ternaryStr(isempty(aMax),'inf', num2str(aMax)), height(T), n0, 100*height(T)/n0);
if height(T) < 10
    warning('applyAlphaFilter:thin', ...
            ['Only %d runs survive the filter. Correlations and binned medians ' ...
             'below rest on very little.'], height(T));
end
end
