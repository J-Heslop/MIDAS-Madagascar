function checkCascadeSignal(matPath)
% checkCascadeSignal  --  is the cascade metric noise, or is the buffer inert?
%
%   checkCascadeSignal
%   checkCascadeSignal('evaluationOutputs.mat')
%
% THE QUESTION
% PRCC on the Set 20 runs found NOTHING driving cascadeContrast_south: max
% |PRCC| 0.144, no parameter above 0.15, and the buffer parameters absent.
% cascadeContrast is the multi-year compounding signature -- the second of the
% paper's three validation signatures, and the one the asset buffer was added
% to produce. Two very different readings:
%
%   (a) NO POWER. The metric is too noisy to correlate with anything.
%       cascadeContrast = mean(anomaly over 3 continuation kere years)
%                       - mean(anomaly over 4 first-of-cascade years).
%       That is a difference of two means built from 3 and 4 annual
%       observations. Compare foodInsecureRate_ag, a ratio of sums over ~880
%       region-years, which scores 0.908. A null on a metric with this little
%       information is uninformative, not evidence of absence.
%
%   (b) NO MECHANISM. The buffer genuinely fails to produce compounding, and
%       the model cannot represent the cascade.
%
% These have opposite implications for the paper, and they are distinguishable
% from data already in hand -- no new runs.
%
% THE TEST
% The campaign ran 2 realisations per parameter set, differing only in seed.
% So for any metric:
%     within-set spread  = pure stochastic noise
%     between-set spread = noise + parameter signal
% If the two are comparable, the metric carries no reproducible parameter
% signal and (a) holds. The intraclass correlation ICC = signal / total
% quantifies it. foodInsecureRate_ag is included as a positive control: it is
% known to carry signal, so it should show a high ICC. If cascadeContrast
% shows ~0 while the control shows ~1, the PRCC null is a power problem.
%
% Also runs a TARGETED two-group test of cascadeContrast against
% bufferCapYears. A single comparison of top vs bottom quartile has far more
% power than a PRCC screen across 81 parameters, and it tests the specific
% prediction: a LARGER buffer should give a SMALLER contrast, because a store
% that is not exhausted by year one leaves less to distinguish year two from
% it.

if nargin < 1 || isempty(matPath)
    matPath = fullfile(fileparts(mfilename('fullpath')), 'evaluationOutputs.mat');
end
if exist(matPath, 'file') ~= 2
    error('checkCascadeSignal:notFound', ...
        'No %s. Run buildNextRound first -- it caches the per-run tables there.', matPath);
end

L = load(matPath);
fn = fieldnames(L);
inTab = []; outTab = [];
for k = 1:numel(fn)
    v = L.(fn{k});
    if istable(v)
        if any(strcmpi(v.Properties.VariableNames, 'cascadeContrast_south'))
            outTab = v;
        elseif isempty(inTab) && width(v) > 5
            inTab = v;
        end
    end
end
if isempty(outTab)
    error('checkCascadeSignal:noOutputs', ...
        ['No table with cascadeContrast_south in %s. Variables present: %s'], ...
        matPath, strjoin(fn', ', '));
end
fprintf('Loaded %d runs from %s\n', height(outTab), matPath);

% --- group runs by identical parameter vector (the realisation pairs) ----
if isempty(inTab) || height(inTab) ~= height(outTab)
    error('checkCascadeSignal:noInputs', ...
        ['Could not match an input table to the outputs, so realisations ' ...
         'cannot be grouped. This test needs both.']);
end
numericCols = varfun(@isnumeric, inTab, 'OutputFormat', 'uniform');
P = table2array(inTab(:, numericCols));
[~, ~, grp] = unique(P, 'rows', 'stable');
nSets = max(grp);
reps  = accumarray(grp, 1);
fprintf('%d unique parameter sets, mean %.2f realisations each\n', nSets, mean(reps));
if all(reps < 2)
    error('checkCascadeSignal:singleRealisation', ...
        ['Every parameter set appears once, so within-set noise cannot be ' ...
         'separated from between-set signal. This test needs >= 2 ' ...
         'realisations per set.']);
end

% --- ICC for each metric of interest ------------------------------------
metrics = {'cascadeContrast_south', 'kereExcess_south', 'kereLagExcess_south', ...
           'distressKereExcess_south', 'foodInsecureRate_ag', 'agFrac_nat_run'};
fprintf('\n%-28s %9s %9s %9s %8s\n', 'metric', 'SD total', 'SD noise', 'SD signal', 'ICC');
for k = 1:numel(metrics)
    m = metrics{k};
    if ~any(strcmpi(outTab.Properties.VariableNames, m)); continue; end
    y = double(outTab.(m));
    ok = isfinite(y);
    if sum(ok) < 10; continue; end

    % One-way random-effects ANOVA on the grouping.
    g = grp(ok); yy = y(ok);
    grand = mean(yy);
    setMeans = accumarray(g, yy, [], @mean);
    setN     = accumarray(g, 1);
    used     = setN >= 2;                       % only sets with repeats inform MSW
    SSB = sum(setN .* (setMeans - grand).^2);
    dfB = numel(setN) - 1;
    SSW = sum((yy - setMeans(g)).^2);
    dfW = numel(yy) - numel(setN);
    if dfW <= 0 || dfB <= 0; continue; end
    MSB = SSB / dfB;  MSW = SSW / dfW;
    kbar = mean(setN(used));
    icc  = max(0, (MSB - MSW) / (MSB + (kbar - 1) * MSW));
    sdNoise  = sqrt(MSW);
    sdSignal = sqrt(max(0, (MSB - MSW) / kbar));
    fprintf('%-28s %9.4f %9.4f %9.4f %8.3f\n', m, std(yy), sdNoise, sdSignal, icc);
end

fprintf(['\nICC near 0 means realisations of the SAME parameters differ as much as\n' ...
         'different parameters do -- the metric is noise, and its PRCC null says\n' ...
         'nothing about the mechanism. Compare against foodInsecureRate_ag, which\n' ...
         'is known to carry signal (PRCC 0.908).\n']);

% --- targeted buffer test -----------------------------------------------
bufCol = '';
for c = string(inTab.Properties.VariableNames)
    if contains(lower(c), 'buffercapyears'); bufCol = char(c); break; end
end
if isempty(bufCol)
    fprintf('\nNo bufferCapYears column found; skipping the targeted test.\n');
    return;
end

b = double(inTab.(bufCol));
y = double(outTab.cascadeContrast_south);
ok = isfinite(b) & isfinite(y);
b = b(ok); y = y(ok);
qlo = quantile(b, 0.25); qhi = quantile(b, 0.75);
lo = y(b <= qlo); hi = y(b >= qhi);

fprintf('\n=== TARGETED: cascadeContrast vs %s ===\n', bufCol);
fprintf('  small buffer (<= %.3f):  n=%3d  mean %+.4f  sd %.4f\n', qlo, numel(lo), mean(lo), std(lo));
fprintf('  large buffer (>= %.3f):  n=%3d  mean %+.4f  sd %.4f\n', qhi, numel(hi), mean(hi), std(hi));
d = mean(lo) - mean(hi);
se = sqrt(var(lo)/numel(lo) + var(hi)/numel(hi));
fprintf('  difference (small - large) %+.4f   SE %.4f   t = %+.2f\n', d, se, d/max(se, eps));
fprintf(['\n  PREDICTION: a small buffer is exhausted by year one, so year two lands\n' ...
         '  on income alone and the contrast is LARGER. Expect small - large > 0.\n' ...
         '  |t| > 2 with the right sign supports the mechanism; |t| < 1 with a near-\n' ...
         '  zero ICC above means the metric cannot resolve it either way.\n']);
end
