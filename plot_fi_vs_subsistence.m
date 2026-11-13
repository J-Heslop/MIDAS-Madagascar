function T = plot_fi_vs_subsistence(runDir, varargin)
% PLOT_FI_VS_SUBSISTENCE  Identify subsistence_costs against the FI target.
%
%   plot_fi_vs_subsistence(runDir)
%   plot_fi_vs_subsistence(runDir, 'Filter', {'droughtScale', 0.25, 0.42})
%   plot_fi_vs_subsistence(runDir, 'Filter', { ...
%        'droughtScale',        0.25, 0.42; ...
%        'incomeShareFraction', 0.25, 0.35})
%
% WHY CONDITION ON OTHER PARAMETERS
% Food insecurity is moved by four things, not one. Across 271 runs the partial
% rank correlations were subsistence +0.76, network sharing -0.62, the distress
% threshold +0.52 and the drought scale factor +0.47. Reading a crossing off
% the unconditioned scatter therefore identifies subsistence only for whatever
% mixture of the other three the ensemble happened to sample.
%
% The three have since been settled by other means: alpha to 0.25-0.42 from
% documented yield losses, sharing declared at 0.30, the distress threshold
% declared at 0.50. Filtering the ensemble to runs near those values gives a
% crossing conditioned on the configuration actually being carried forward,
% which is the quantity wanted.
%
% WHICH SUMMARY IT READS
% fi_drivers_summary.csv by preference, because that extraction keeps EVERY
% sampled parameter and so can be filtered on any of them. It falls back to
% distress_threshold_summary.csv, which carries only a handful of columns and
% cannot condition on sharing. Neither is re-read from the .mat files here;
% build them with fi_drivers(runDir,'Refresh',true) if they are missing.
%
% READ THE SCATTER, NOT A POINT. Take the span of subsistence values whose
% runs bracket the target, not the single closest run. Filtering costs runs,
% so check the retained count before trusting a narrow answer.

p = inputParser;
p.addRequired('runDir', @(x) ischar(x) || isstring(x));
p.addParameter('Target',    3.8/12, @isnumeric);
p.addParameter('Tolerance', 0.03,   @isnumeric);
% Each row is {column-name-pattern, min, max}. Use [] for an open end. The
% pattern is matched case-insensitively against the column names, so
% 'incomeShareFraction' finds agentParameters_incomeShareFractionMean without
% needing to know how the name was sanitised on the way into the CSV.
p.addParameter('Filter', {}, @(x) iscell(x) || isempty(x));
p.parse(runDir, varargin{:});
opt = p.Results; runDir = char(opt.runDir); TARGET = opt.Target;
if ~isfolder(runDir)
    error('plot_fi_vs_subsistence:badDir', 'Directory does not exist: %s', runDir);
end

% ---------------------------------------------------------------- load
T = []; srcName = ''; diag = {};
for cand = {'fi_drivers_summary.csv', 'distress_threshold_summary.csv'}
    f = fullfile(runDir, cand{1});
    if ~exist(f, 'file')
        diag{end+1} = sprintf('  %-34s not present', cand{1}); %#ok<AGROW>
        continue;
    end
    try
        Ttry = readSummaryCsv(f);
    catch err
        diag{end+1} = sprintf('  %-34s readtable failed: %s', cand{1}, err.message); %#ok<AGROW>
        continue;
    end
    hasSubs = ~isempty(findCol(Ttry, 'subsist'));
    hasFI   = ~isempty(findCol(Ttry, 'fi_nat'));
    if hasSubs && hasFI
        T = Ttry; srcName = cand{1}; break;
    end
    % Report exactly which test failed and what the file actually holds. A
    % bare "no usable summary" sends you rebuilding a file that already
    % exists, which is what happened the first time this fired.
    diag{end+1} = sprintf(['  %-34s %d rows, %d cols; subsistence column %s, ' ...
                           'fi_nat column %s\n      first columns: %s'], ...
        cand{1}, height(Ttry), width(Ttry), ...
        ternaryStr(hasSubs,'FOUND','MISSING'), ternaryStr(hasFI,'FOUND','MISSING'), ...
        strjoin(Ttry.Properties.VariableNames(1:min(8,end)), ', ')); %#ok<AGROW>
end
if isempty(T)
    error('plot_fi_vs_subsistence:noSummary', ...
          ['No usable summary in %s.\n%s\n' ...
           'A summary needs one column matching "subsist" and one matching ' ...
           '"fi_nat".\nIf both files above look wrong, rebuild with ' ...
           'fi_drivers(''%s'', ''Refresh'', true).'], ...
          runDir, strjoin(diag, newline), runDir);
end
fprintf('Reading %s (%d runs).\n', srcName, height(T));

SUBS = findCol(T, 'subsistence');

% ---------------------------------------------------------------- filter
if ~isempty(opt.Filter)
    F = opt.Filter;
    if size(F,2) ~= 3
        error('plot_fi_vs_subsistence:badFilter', ...
              'Filter must be an n-by-3 cell array: {pattern, min, max}.');
    end
    for k = 1:size(F,1)
        pat = F{k,1}; lo = F{k,2}; hi = F{k,3};
        col = findCol(T, pat);
        if isempty(col)
            % Name the columns that nearly matched. A silent no-match here
            % would leave the ensemble unfiltered and the crossing wrong, with
            % nothing on screen to say so.
            near = T.Properties.VariableNames( ...
                       contains(lower(T.Properties.VariableNames), lower(pat(1:min(6,end)))));
            error('plot_fi_vs_subsistence:noColumn', ...
                  ['No column matching "%s".\nClosest names: %s\n' ...
                   'If the summary predates this parameter, rebuild with ' ...
                   'fi_drivers(..., ''Refresh'', true).'], ...
                  pat, ternaryStr(isempty(near), '(none)', strjoin(near, ', ')));
        end
        n0 = height(T); keep = true(n0,1);
        if ~isempty(lo); keep = keep & T.(col) >= lo; end
        if ~isempty(hi); keep = keep & T.(col) <= hi; end
        T = T(keep,:);
        fprintf('  %-46s [%s, %s] -> %3d of %3d kept\n', col, ...
                ternaryStr(isempty(lo),'-inf',num2str(lo)), ...
                ternaryStr(isempty(hi),'inf', num2str(hi)), height(T), n0);
    end
    fprintf('\n');
end

T = T(~isnan(T.(SUBS)) & ~isnan(T.fi_nat), :);
if height(T) < 4
    error('plot_fi_vs_subsistence:tooFew', ...
          ['Only %d runs survive the filters. Widen them, or accept that this ' ...
           'ensemble cannot answer the question at this conditioning.'], height(T));
end
if height(T) < 15
    warning('plot_fi_vs_subsistence:thin', ...
            ['%d runs after filtering. The crossing below rests on very ' ...
             'little; treat the span as indicative.'], height(T));
end

x = T.(SUBS); yN = T.fi_nat;
yG = nan(height(T),1);
if ismember('fi_gs', T.Properties.VariableNames); yG = T.fi_gs; end

% ---------------------------------------------------------------- figure
f = figure('Color','w','Position',[100 100 780 470]);
ax = axes(f); hold(ax,'on'); box(ax,'on');
xl = [min(x) max(x)];
hb = patch(ax, [xl fliplr(xl)], ...
           [TARGET-opt.Tolerance TARGET-opt.Tolerance ...
            TARGET+opt.Tolerance TARGET+opt.Tolerance], ...
           [0.20 0.60 0.35], 'FaceAlpha', 0.12, 'EdgeColor','none');
ht = plot(ax, xl, [TARGET TARGET], '-', 'Color',[0.15 0.45 0.25], 'LineWidth',1.4);
hN = scatter(ax, x, yN, 36, [0.78 0.24 0.20], 'filled', 'MarkerFaceAlpha',0.8);
hG = scatter(ax, x, yG, 36, [0.30 0.45 0.70], 'filled', 'MarkerFaceAlpha',0.8);

% ---------------------------------------------------------------- fits
% CANDIDATE FUNCTIONAL FORMS (2026-09-12).
%
% The relationship is not linear, and it should not be: food insecurity is a
% SHARE, bounded [0,1]. As subsistence cost falls toward zero nobody is
% food-insecure; as it rises without limit everyone is. A straight line
% satisfies neither end and can cross the target at a value the curve never
% reaches, which is the one thing this figure exists to avoid.
%
% Six forms are fitted and compared. The logistic is the conceptually
% principled one -- a proportion modelled through a logit link, bounded by
% construction -- so if it is close to the best on fit statistics, prefer it
% over a marginally better descriptive curve.
%
% FAIR COMPARISON. Every form is scored on residuals in the ORIGINAL y units,
% never in a transformed space. A power law fitted in log-log minimises log
% error, which flatters it against a linear fit scored on the raw scale; that
% comparison would be meaningless. Starting values come from the linearised
% solution where one exists, then fminsearch refines on the original scale.
% fminsearch is base MATLAB -- no Optimization Toolbox dependency.
xf = linspace(xl(1), xl(2), 200)';
fits = fitFICurves(x, yN, TARGET);

% Plot all candidates faintly, the selected one boldly, so the reader can see
% how much the choice of form matters rather than taking it on trust.
hAll = gobjects(numel(fits),1);
for iC = 1:numel(fits)
    hAll(iC) = plot(ax, xf, fits(iC).pred(xf), '-', ...
                    'Color', [0.55 0.55 0.55 0.45], 'LineWidth', 0.9);
end
[~, iBest] = min([fits.aicc]);
% Prefer the logistic when it is within 2 AICc of the best: a difference that
% small is not evidence for one form over another, and the logistic is the one
% with a reason behind it.
iLogit = find(strcmp({fits.name}, 'logistic'), 1);
if ~isempty(iLogit) && (fits(iLogit).aicc - fits(iBest).aicc) < 2
    iSel = iLogit;
else
    iSel = iBest;
end
hF = plot(ax, xf, fits(iSel).pred(xf), '-', ...
          'Color',[0.78 0.24 0.20], 'LineWidth', 2.2);

xlabel(ax, 'agentParameters.subsistence\_costs (per quarter, sampled)');
ylabel(ax, 'food-insecure share of working-age agricultural agent-years');
ttl = sprintf('Food insecurity against subsistence cost, 2000-2018 (%d runs', height(T));
if ~isempty(opt.Filter); ttl = [ttl ', filtered']; end
title(ax, [ttl ')'], 'FontWeight','bold');
legend(ax, [hN hG hF hAll(1) ht hb], ...
       {'national', 'Grand Sud', ...
        sprintf('%s fit (selected)', fits(iSel).name), ...
        'other candidate forms', ...
        sprintf('Harvey et al. target, %.3f', TARGET), ...
        sprintf('target \\pm %.2f', opt.Tolerance)}, ...
       'Location','northwest','FontSize',8,'Box','off');
grid(ax,'on'); ax.GridAlpha = 0.12;
png = fullfile(runDir, 'fig_fi_vs_subsistence.png');
exportgraphics(f, png, 'Resolution', 200);
fprintf('Wrote %s\n', png);

% ---------------------------------------------------------------- readout
fprintf('\n=== Food insecurity vs subsistence cost ===\n');
fprintf('Target %.3f. Subsistence sampled %.2f to %.2f across the retained runs.\n', ...
        TARGET, min(x), max(x));
fprintf('FI national %.3f to %.3f (median %.3f); Grand Sud median %.3f.\n', ...
        min(yN), max(yN), median(yN), median(yG,'omitnan'));

rho = corr(x, yN, 'type','Spearman');
fprintf('\nSpearman(subsistence, FI) = %+.2f\n', rho);
if rho < 0.4
    fprintf(2, ['Weak. Subsistence is not ordering food insecurity in this ' ...
                'subset, so do not\nread a crossing off the fit.\n']);
end

% ---- candidate forms, scored on the original scale -----------------------
fprintf('\n%-12s %6s %8s %9s %9s  %s\n', ...
        'form','k','RMSE','R2','dAICc','crossing at target');
fprintf('%s\n', repmat('-',1,64));
[~, ord] = sort([fits.aicc]);
for iC = ord
    fc = fits(iC);
    mark = '';
    if iC == iSel; mark = '  <-- selected'; end
    if isnan(fc.xcross)
        xs = 'no crossing';
    elseif fc.xcross < min(x) || fc.xcross > max(x)
        xs = sprintf('%.2f  EXTRAPOLATED', fc.xcross);
    else
        xs = sprintf('%.2f', fc.xcross);
    end
    fprintf('%-12s %6d %8.4f %9.3f %9.1f  %-22s%s\n', ...
            fc.name, fc.k, fc.rmse, fc.r2, fc.aicc - min([fits.aicc]), xs, mark);
end
fprintf(['\nSelected: %s. dAICc is relative to the best form; a gap under 2 is ' ...
         'not\nevidence for one over another, so the logistic is preferred on ' ...
         'those terms --\nit is the only candidate bounded to [0,1] by ' ...
         'construction, which a share must be.\n'], fits(iSel).name);

xcSel = fits(iSel).xcross;
if ~isnan(xcSel)
    if xcSel < min(x) || xcSel > max(x)
        fprintf(2, ['\nThe selected crossing (%.2f) lies OUTSIDE the sampled range ' ...
                    '%.2f-%.2f.\nThat is extrapolation, not evidence -- widen the ' ...
                    'prior and re-run.\n'], xcSel, min(x), max(x));
    end
    % Spread across forms is the honest uncertainty in the crossing: if the
    % candidates disagree by more than the in-band span below, the functional
    % form is doing more work than the data.
    xcAll = [fits.xcross];
    xcAll = xcAll(~isnan(xcAll) & xcAll >= min(x) & xcAll <= max(x));
    if numel(xcAll) > 1
        fprintf('Crossings across forms that stay in range: %.2f to %.2f.\n', ...
                min(xcAll), max(xcAll));
    end
end

inBand = abs(yN - TARGET) <= opt.Tolerance;
fprintf('\n%d of %d runs land within %.2f of target.\n', nnz(inBand), height(T), opt.Tolerance);
if any(inBand)
    fprintf('Their subsistence_costs span %.2f to %.2f (median %.2f).\n', ...
            min(x(inBand)), max(x(inBand)), median(x(inBand)));
    fprintf(['That span is the range to carry forward: it is what the model ' ...
             'actually produced\non target, rather than where a line through ' ...
             'a cloud happens to cross.\n']);
else
    fprintf(2, ['NO retained run reproduced the target. Either the conditioning ' ...
                'is wrong or the\nsubsistence prior does not reach the value ' ...
                'that would hit it -- widen and re-run.\n']);
end
end

% =========================================================================
function col = findCol(T, pat)
% Case-insensitive substring match on column names, so callers need not know
% how a dotted parameter name was sanitised into the CSV.
vn = T.Properties.VariableNames;
hit = find(contains(lower(vn), lower(pat)), 1);
col = '';
if ~isempty(hit); col = vn{hit}; end
end

function o = ternaryStr(c,a,b)
if c; o=a; else; o=b; end
end

% =========================================================================
function fits = fitFICurves(x, y, target)
% Fit candidate forms to a bounded share and score them on the ORIGINAL scale.
%
% Returns a struct array with fields: name, k, pred (function handle), rmse,
% r2, aicc, xcross (subsistence at which the fit reaches `target`, NaN if the
% form never reaches it).
%
% WHY NOT JUST FIT IN TRANSFORMED SPACE. A power law is trivially fitted by
% regressing log(y) on log(x), and a logistic by regressing logit(y) on x. Both
% minimise error in the transformed units, which is a different objective and
% makes them look better than a linear fit scored on the raw scale. Those
% solutions are used only as STARTING VALUES; fminsearch then minimises the sum
% of squares in y, so every form is scored against the same objective.
%
% AICc rather than AIC because n here is the number of retained runs, which
% after filtering can be small relative to the parameter count.
x = x(:); y = y(:);
n = numel(x);
sst = sum((y - mean(y)).^2);

% Guard the transforms: logit needs y strictly inside (0,1), logs need x > 0.
eps0 = 1e-6;
yc = min(max(y, eps0), 1 - eps0);
xp = max(x, eps0);

sse = @(f, b) sum((y - f(b, x)).^2);
refine = @(f, b0) fminsearch(@(b) sse(f, b), b0, ...
                             optimset('Display','off','MaxFunEvals',4000,'MaxIter',4000));

C = {};
% 1. linear -- the previous behaviour, kept as the baseline to beat.
f = @(b,xx) b(1) + b(2).*xx;
b0 = [ones(n,1) x] \ y;
C{end+1} = struct('name','linear','f',f,'b',refine(f,b0), ...
    'inv', @(b,t) (t - b(1)) ./ b(2));

% 2. quadratic -- descriptive only, no theory behind it; included so a real
%    curvature in the data is not missed.
f = @(b,xx) b(1) + b(2).*xx + b(3).*xx.^2;
b0 = [ones(n,1) x x.^2] \ y;
C{end+1} = struct('name','quadratic','f',f,'b',refine(f,b0), ...
    'inv', @(b,t) quadRoot(b(3), b(2), b(1) - t));

% 3. power -- y = a*x^b.
f = @(b,xx) b(1) .* xx.^b(2);
bl = [ones(n,1) log(xp)] \ log(max(y,eps0));
b0 = [exp(bl(1)); bl(2)];
C{end+1} = struct('name','power','f',f,'b',refine(f,b0), ...
    'inv', @(b,t) (t ./ b(1)).^(1 ./ b(2)));

% 4. log-linear -- y = a + b*log(x).
f = @(b,xx) b(1) + b(2).*log(max(xx,eps0));
b0 = [ones(n,1) log(xp)] \ y;
C{end+1} = struct('name','log-linear','f',f,'b',refine(f,b0), ...
    'inv', @(b,t) exp((t - b(1)) ./ b(2)));

% 5. logistic -- the principled form. A share is a proportion; a logit link
%    keeps the fit inside [0,1] at both ends by construction.
f = @(b,xx) 1 ./ (1 + exp(-(b(1) + b(2).*xx)));
b0 = [ones(n,1) x] \ log(yc ./ (1 - yc));
C{end+1} = struct('name','logistic','f',f,'b',refine(f,b0), ...
    'inv', @(b,t) (log(t ./ (1 - t)) - b(1)) ./ b(2));

% 6. saturating -- y = 1 - exp(-a*x^b). Also bounded above by 1, but reaches 0
%    only at x = 0; a useful contrast with the logistic.
f = @(b,xx) 1 - exp(-b(1) .* max(xx,eps0).^b(2));
C{end+1} = struct('name','saturating','f',f,'b',refine(f,[0.1; 2]), ...
    'inv', @(b,t) (-log(1 - t) ./ b(1)).^(1 ./ b(2)));

fits = struct('name',{},'k',{},'pred',{},'rmse',{},'r2',{},'aicc',{},'xcross',{});
for i = 1:numel(C)
    c = C{i}; b = c.b; k = numel(b);
    r = y - c.f(b, x);
    ss = sum(r.^2);
    % AICc for least squares with unknown variance; k+1 counts sigma.
    kk = k + 1;
    aicc = n*log(ss/n) + 2*kk + (2*kk*(kk+1)) / max(n - kk - 1, 1);
    xc = NaN;
    try
        xc = c.inv(b, target);
        if ~isreal(xc) || ~isfinite(xc); xc = NaN; end
    catch
        xc = NaN;
    end
    fits(end+1) = struct('name', c.name, 'k', k, ...
        'pred', @(xx) c.f(b, xx), 'rmse', sqrt(ss/n), ...
        'r2', 1 - ss/max(sst,eps), 'aicc', aicc, 'xcross', xc); %#ok<AGROW>
end
end

function r = quadRoot(a, b, c)
% Real root of a*x^2 + b*x + c, preferring the positive one. NaN if none.
if abs(a) < eps; r = -c / b; return; end
d = b^2 - 4*a*c;
if d < 0; r = NaN; return; end
rts = [(-b + sqrt(d)) / (2*a), (-b - sqrt(d)) / (2*a)];
rts = rts(rts > 0);
if isempty(rts); r = NaN; else; r = min(rts); end
end
