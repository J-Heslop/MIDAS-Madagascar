function T = fi_drivers(runDir, varargin)
% FI_DRIVERS  What drives food insecurity besides subsistence cost?
%
%   T = fi_drivers('D:\MIDAS outputs\Outputs_..._WideChar')
%   T = fi_drivers(runDir, 'Refresh', true)
%
% THE QUESTION
% At a fixed subsistence cost the modelled food-insecure fraction spans a wide
% range -- roughly 4% to 48% at 2.15 in the campaign that prompted this. That
% spread is not noise in any useful sense: it is other sampled parameters
% moving the same output. This ranks them.
%
% METHOD
% Every sampled parameter is read from each run's own `input` table, so the
% set adapts to whatever the campaign varied rather than being hard-coded.
% Two statistics are reported per parameter:
%
%   rho      Spearman rank correlation with the food-insecure fraction.
%   prcc     The same, PARTIAL on subsistence cost -- the association that
%            remains once subsistence is held constant. This is the direct
%            answer to "what else is doing this", because it removes the
%            variation subsistence already explains.
%
% Rank-based rather than linear throughout: these relationships are monotone
% but not straight, and a Pearson correlation on a saturating response
% understates it.
%
% WHAT TO EXPECT, AND WHY IT IS NOT A SURPRISE
% Food insecurity is recorded when an unmet subsistence requirement REMAINS
% after income has been spent and the livestock and grain store drawn down to
% its floor. Every parameter governing that store therefore sits between the
% income shortfall and the recorded outcome:
%
%   bufferCapYears     0.5 - 3.0   how many years of food the store can hold
%   bufferFloorYears   0.0 - 0.5   how much of it is defended and cannot be eaten
%   bufferMortalityMax 0.1 - 0.8   how fast the herd dies during drought
%   bufferAccrualFrac  0.1 - 0.7   how fast it rebuilds afterwards
%
% A sixfold range on the first alone will move the food-insecure fraction a
% long way at any subsistence cost. That is a property of the definition, not
% a defect -- but it does mean subsistence cannot be identified against food
% insecurity without saying what the buffer was doing at the same time.

p = inputParser;
p.addRequired('runDir', @(x) ischar(x) || isstring(x));
p.addParameter('Refresh', false, @islogical);
p.addParameter('CsvName', 'fi_drivers_summary.csv', @(x) ischar(x)||isstring(x));
p.addParameter('TopN', 12, @isnumeric);
p.addParameter('AlphaMin', [], @(x) isempty(x) || isnumeric(x));
p.addParameter('AlphaMax', [], @(x) isempty(x) || isnumeric(x));
p.parse(runDir, varargin{:});
opt = p.Results; runDir = char(opt.runDir);
if ~isfolder(runDir)
    error('fi_drivers:badDir', 'Directory does not exist: %s', runDir);
end
csvPath = fullfile(runDir, char(opt.CsvName));

SUBS = 'agentParameters_subsistence_costs';   % column name after sanitising

% ---------------------------------------------------------------- extract
if exist(csvPath,'file') && ~opt.Refresh
    fprintf('Reading cached summary: %s\n(pass ''Refresh'',true to re-read)\n\n', csvPath);
    T = readSummaryCsv(csvPath);
else
    T = extractAll(runDir);
    writetable(T, csvPath);
    fprintf('\nWrote %s (%d runs, %d parameters).\n', csvPath, height(T), width(T)-2);
end

% Locate the drought scale factor by pattern rather than by exact name.
% readtable and makeValidName do not always agree on how a dotted parameter
% name is sanitised, and an exact-match failure here sends you hunting through
% a 70-column CSV for a spelling difference.
ALPHA = '';
vn = T.Properties.VariableNames;
hit = find(contains(lower(vn), 'droughtscale'), 1);
if ~isempty(hit); ALPHA = vn{hit}; end
if ~isempty(opt.AlphaMin) || ~isempty(opt.AlphaMax)
    if isempty(ALPHA)
        cand = vn(contains(lower(vn), 'drought'));
        error('fi_drivers:noAlpha', ...
              ['No column matching "droughtScale" in the cached summary.\n' ...
               'Columns containing "drought": %s\n' ...
               'If none, the cache predates this parameter -- re-run with ' ...
               '''Refresh'', true.'], ...
              ternaryStr(isempty(cand), '(none)', strjoin(cand, ', ')));
    end
    fprintf('Filtering on column "%s".\n', ALPHA);
    n0 = height(T); keep = true(n0,1);
    if ~isempty(opt.AlphaMin); keep = keep & T.(ALPHA) >= opt.AlphaMin; end
    if ~isempty(opt.AlphaMax); keep = keep & T.(ALPHA) <= opt.AlphaMax; end
    T = T(keep,:);
    fprintf('Filtered on droughtScaleFactor: %d of %d runs retained (%.0f%%).\n', ...
            height(T), n0, 100*height(T)/n0);
    fprintf(['NOTE: alpha now varies little by construction, so its own partial\n' ...
             'correlation below will collapse. That is the filter, not a finding.\n\n']);
end
T = T(~isnan(T.fi_nat), :);
if height(T) < 8
    error('fi_drivers:tooFew', 'Only %d usable runs; correlations would be meaningless.', height(T));
end
if ~ismember(SUBS, T.Properties.VariableNames)
    error('fi_drivers:noSubs', 'subsistence_costs not found among the sampled parameters.');
end

% ---------------------------------------------------------------- rank stats
y = T.fi_nat;
s = T.(SUBS);
names = setdiff(T.Properties.VariableNames, {'file','fi_nat','fi_gs'}, 'stable');

% Drop anything that did not actually vary -- a pinned parameter has no rank
% and would return NaN, or worse, a spurious correlation from rounding.
keep = false(numel(names),1);
for i = 1:numel(names)
    v = T.(names{i});
    keep(i) = isnumeric(v) && ~all(isnan(v)) && range(v(~isnan(v))) > eps;
end
pinned = names(~keep); names = names(keep);
fprintf('%d parameters varied; %d were pinned and are excluded.\n\n', numel(names), numel(pinned));

rho  = nan(numel(names),1);
prcc = nan(numel(names),1);
rys  = corr(y, s, 'type','Spearman', 'rows','complete');
for i = 1:numel(names)
    x = T.(names{i});
    rho(i) = corr(y, x, 'type','Spearman', 'rows','complete');
    if strcmp(names{i}, SUBS)
        prcc(i) = rho(i);            % partialling subsistence on itself is meaningless
        continue;
    end
    rxs = corr(x, s, 'type','Spearman', 'rows','complete');
    den = sqrt((1-rys^2)*(1-rxs^2));
    if den > eps
        prcc(i) = (rho(i) - rys*rxs) / den;
    end
end

[~, ord] = sort(abs(prcc), 'descend', 'MissingPlacement','last');
n = min(opt.TopN, numel(ord));

fprintf('=== Drivers of the food-insecure fraction (%d runs) ===\n', height(T));
fprintf('%-46s %8s %8s\n', 'parameter', 'rho', 'partial');
fprintf('%s\n', repmat('-',1,64));
for k = 1:n
    i = ord(k);
    fprintf('%-46s %8.2f %8.2f%s\n', names{i}, rho(i), prcc(i), ...
            ternary(strcmp(names{i},SUBS), '   <- the one being calibrated', ''));
end

fprintf('\nSpearman(subsistence, FI) on its own = %+.2f\n', rys);
fprintf('That leaves %.0f%% of the rank variance in FI unexplained by subsistence alone.\n', ...
        100*(1-rys^2));

% ---------------------------------------------------------------- the slice
% Show the effect the way it was noticed: inside a narrow band of subsistence
% cost, where subsistence is effectively held constant by construction.
band = abs(s - median(s)) <= 0.05*range(s);
if nnz(band) >= 6
    top = names{ord(1)};
    if strcmp(top, SUBS) && numel(ord) > 1; top = names{ord(2)}; end
    xb = T.(top)(band); yb = y(band);
    [~, o2] = sort(xb);
    fprintf(['\nWithin a narrow band of subsistence cost (%d runs, %.2f to %.2f):\n' ...
             '  FI ranges %.3f to %.3f\n' ...
             '  %s ranges %.3g to %.3g, and orders those runs with rho = %+.2f\n'], ...
            nnz(band), min(s(band)), max(s(band)), min(yb), max(yb), ...
            top, min(xb), max(xb), corr(xb, yb, 'type','Spearman'));
end

% ---------------------------------------------------------------- figure
f = figure('Color','w','Position',[100 100 900 460]);
tl = tiledlayout(f,1,2,'TileSpacing','compact','Padding','compact');

ax = nexttile(tl); barh(ax, prcc(ord(n:-1:1)), 'FaceColor',[0.30 0.45 0.70]);
set(ax,'YTick',1:n,'YTickLabel',strrep(names(ord(n:-1:1)),'_','\_'),'FontSize',8);
xlabel(ax,'partial rank correlation with FI, subsistence held constant');
title(ax,'What else moves food insecurity','FontWeight','normal');
grid(ax,'on'); ax.GridAlpha=0.12;

ax2 = nexttile(tl); hold(ax2,'on'); box(ax2,'on');
top = names{ord(1)}; if strcmp(top,SUBS) && numel(ord)>1; top = names{ord(2)}; end
sc = scatter(ax2, s, y, 40, T.(top), 'filled'); sc.MarkerFaceAlpha = 0.85;
cb = colorbar(ax2); cb.Label.String = strrep(top,'_','\_');
xlabel(ax2,'agentParameters.subsistence\_costs'); ylabel(ax2,'food-insecure fraction');
title(ax2,'Same scatter, coloured by the strongest secondary driver','FontWeight','normal');
yline(ax2, 3.8/12, '-', 'Harvey target', 'Color',[0.15 0.45 0.25], 'LineWidth',1.3);
grid(ax2,'on'); ax2.GridAlpha=0.12;

png = fullfile(runDir,'fig_fi_drivers.png');
exportgraphics(f, png, 'Resolution',200);
fprintf('\nWrote %s\n', png);
end

% =========================================================================
function T = extractAll(runDir)
files = dir(fullfile(runDir,'MC*.mat'));
if isempty(files); error('fi_drivers:noFiles','No MC*.mat in %s', runDir); end
n = numel(files);
fprintf('Reading %d MC files from %s\n(slow step, cached afterwards)\n', n, runDir);

rows = cell(n,1);
parfor iF = 1:n
    fp = fullfile(files(iF).folder, files(iF).name);
    s = struct('file', string(files(iF).name), 'fi_nat', NaN, 'fi_gs', NaN);
    try
        D = load(fp, 'input', 'output');
    catch err
        warning('fi_drivers:badFile','Skipping %s (%s)', files(iF).name, err.message);
        rows{iF} = s; continue;
    end

    % every sampled parameter, named as in the input table
    spin = NaN;
    if isfield(D,'input')
        inp = D.input; nm=[]; vv=[];
        if istable(inp) && all(ismember({'parameterNames','parameterValues'}, inp.Properties.VariableNames))
            nm = inp.parameterNames; vv = inp.parameterValues;
        elseif isstruct(inp) && isfield(inp,'parameterNames')
            nm = inp.parameterNames; vv = inp.parameterValues;
        end
        for k = 1:numel(nm)
            raw = nm(k); if iscell(raw); raw = raw{1}; end
            key = matlab.lang.makeValidName(strrep(string(raw),'.','_'));
            s.(key) = double(vv(k));
            if strcmp(char(raw),'modelParameters.spinupTime'); spin = double(vv(k)); end
        end
    end

    if ~isfield(D,'output') || ~isstruct(D.output); rows{iF}=s; continue; end
    o = D.output;
    if ~all(isfield(o,{'foodInsecureCount_ag','agentCount_ag','outMigrations'}))
        rows{iF}=s; continue;
    end
    if isnan(spin); spin = 10; end

    % geometry, per run, as in plot_distress_threshold
    nT = size(o.outMigrations,2); cyc = 4;
    numCycles = (nT - spin)/cyc;
    if abs(numCycles-round(numCycles))>1e-9 || numCycles<1; rows{iF}=s; continue; end
    spinYears = ceil(spin/cyc);
    nValid = floor(nT/cyc) - spinYears;
    years  = 1985 + (1:nValid);

    fi = double(o.foodInsecureCount_ag); na = double(o.agentCount_ag);
    w  = min([size(fi,2), size(na,2), nValid]);
    m  = years(1:w) >= 2000 & years(1:w) <= 2018;     % buildNextRound's window
    s.fi_nat = sum(sum(fi(:,1:w).*m)) / max(sum(sum(na(:,1:w).*m)), eps);
    gs = [19 20 21];
    s.fi_gs  = sum(sum(fi(gs,1:w).*m)) / max(sum(sum(na(gs,1:w).*m)), eps);

    rows{iF} = s;
end

flds = {};
for k=1:n; flds = union(flds, fieldnames(rows{k}), 'stable'); end
T = table();
for i = 1:numel(flds)
    f = flds{i};
    if strcmp(f,'file')
        c = strings(n,1);
        for k=1:n; c(k) = getdef(rows{k},f,""); end
    else
        c = nan(n,1);
        for k=1:n; c(k) = getdef(rows{k},f,NaN); end
    end
    T.(f) = c;
end
end

function v = getdef(s,f,d)
if isfield(s,f) && ~isempty(s.(f)); v = s.(f); else; v = d; end
end
function o = ternary(c,a,b)
if c; o=a; else; o=b; end
end
function o = ternaryStr(c,a,b)
if c; o=a; else; o=b; end
end
