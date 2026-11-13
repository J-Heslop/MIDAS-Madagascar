function T = plot_mobility_classes(runDir, varargin)
% PLOT_MOBILITY_CLASSES  Aspiration/ability composition of agricultural agents.
%
%   plot_mobility_classes('D:\MIDAS outputs\Set 26')
%   plot_mobility_classes(runDir, 'Ensemble', true)   % median + 5-95% ribbon
%
% WHAT IT PLOTS
% Two stacked panels, national above Grand Sud, on SHARED x and y axes so the
% contrast between them is read directly off the height difference rather than
% inferred. Each shows, per model year, the share of AGRICULTURAL agent-quarter
% decisions falling into each aspiration/ability class:
%
%   voluntarily immobile   nothing in reach beat staying; not constrained
%   trapped                wanted to move, could afford nothing better, stayed
%                          (involuntarily immobile)
%   freely mobile          moved, and reached its preferred livelihood/location
%   mobile, not preferred  moved, but its preferred option was unaffordable, so
%                          it took the best it could pay for
%   survival migrant       routed by the distress overlay; affordability is
%                          bypassed, so this is movement to survive rather than
%                          movement chosen
%
% DENOMINATOR: DECISIONS TAKEN, NOT POPULATION.
% Agents evaluate with probability pChoose, so most take no decision in a given
% quarter and carry no class. The share is therefore over agents that actually
% weighed their options -- "of the agricultural households that considered
% their position this quarter, X% wanted to move and could not". A population
% share would be scaled by pChoose, making the level an artefact of a
% calibration parameter rather than a statement about constraint. Say which is
% meant in any caption: the two differ by roughly 1/pChoose.
%
% WHY THIS IS NOT DERIVABLE FROM OLDER OUTPUT
% trappedHistory is per agent with no location and no agricultural split, and
% agentSummary.mobilityClass is an end-state snapshot. mobilityCount_ag was
% added on 2026-09-11 for exactly this figure; runs produced before then do not
% carry it and this script will say so rather than guess.
%
% THE TRAPPED SERIES IS THE POINT. The model's own limitation -- that it cannot
% reproduce the observed concentration of distress moves -- is a statement
% about the distress channel. The trapped share is the complementary quantity:
% households that wanted to move and could not, which is what the aspiration/
% ability literature says a drought-exposed population mostly does.

p = inputParser;
p.addRequired('runDir', @(x) ischar(x) || isstring(x));
p.addParameter('Ensemble', true, @islogical);
p.addParameter('PngName', 'fig_mobility_classes.png', @(x) ischar(x)||isstring(x));
% Model (shapefile) region order, asserted rather than trusted -- the whole
% region-naming episode came from an index that had silently moved.
p.addParameter('GrandSud', [19 20 21], @isnumeric);
p.parse(runDir, varargin{:});
opt = p.Results; runDir = char(opt.runDir);

if ~isfolder(runDir)
    error('plot_mobility_classes:badDir', 'Directory does not exist: %s', runDir);
end
files = dir(fullfile(runDir, 'MC_Run*.mat'));
if isempty(files)
    error('plot_mobility_classes:noRuns', 'No MC_Run*.mat in %s', runDir);
end

CLASS_TRAPPED = 2;
LBL = {'voluntarily immobile','trapped (involuntarily immobile)', ...
       'freely mobile','mobile, not to preferred option','survival migrant'};
% Trapped deliberately dark and distinct; the immobile classes cool, the mover
% classes warm, so the immobile/mobile split is legible before the legend is.
COL = [0.62 0.71 0.80;   % voluntarily immobile
       0.16 0.24 0.36;   % trapped
       0.93 0.69 0.42;   % voluntary migrant
       0.82 0.45 0.24;   % constrained migrant
       0.66 0.19 0.19];  % distress migrant

nat = []; gs = []; nUsed = 0; skipped = 0;
for iF = 1:numel(files)
    S = load(fullfile(runDir, files(iF).name), 'output');
    if ~isfield(S, 'output') || ~isfield(S.output, 'mobilityCount_ag')
        skipped = skipped + 1; continue;
    end
    M = double(S.output.mobilityCount_ag);          % nLoc x nYears x 5
    if ndims(M) ~= 3 || size(M,3) ~= 5
        skipped = skipped + 1; continue;
    end
    % Shares over the class dimension, computed AFTER pooling regions, so a
    % region with few decisions cannot swing the national figure.
    natC = squeeze(sum(M, 1));                      % nYears x 5
    gsC  = squeeze(sum(M(opt.GrandSud,:,:), 1));
    nat(:,:,end+1) = natC ./ max(sum(natC,2), eps); %#ok<AGROW>
    gs(:,:,end+1)  = gsC  ./ max(sum(gsC,2),  eps); %#ok<AGROW>
    nUsed = nUsed + 1;
end
if nUsed == 0
    error('plot_mobility_classes:noField', ...
          ['None of the %d runs in %s carry mobilityCount_ag. That field was ' ...
           'added 2026-09-11; these outputs predate it and the trapped share ' ...
           'cannot be recovered from them (trappedHistory has no location or ' ...
           'agricultural split). Re-run with the current Core_MIDAS_Code.'], ...
          numel(files), runDir);
end
if skipped > 0
    fprintf('Skipped %d of %d runs lacking mobilityCount_ag.\n', skipped, numel(files));
end
fprintf('Using %d runs.\n', nUsed);

startY = 1985;
S1 = load(fullfile(runDir, files(1).name), 'output');
if isfield(S1.output, 'modelYearStart'); startY = S1.output.modelYearStart; end
years = startY + (0:size(nat,1)-1);

% ---------------------------------------------------------------- figure
f = figure('Color','w','Position',[100 100 820 720]);
tl = tiledlayout(f, 2, 1, 'TileSpacing','compact', 'Padding','compact');

axes_ = gobjects(2,1);
for iP = 1:2
    if iP == 1; D = nat; ttl = 'National'; else; D = gs; ttl = 'Grand Sud (Androy, Anosy, Atsimo-Andrefana)'; end
    ax = nexttile(tl); hold(ax,'on'); box(ax,'on'); axes_(iP) = ax;
    med = median(D, 3, 'omitnan');

    h = gobjects(5,1);
    for k = 1:5
        if opt.Ensemble && size(D,3) > 2
            lo = prctile(D(:,k,:), 5,  3);
            hi = prctile(D(:,k,:), 95, 3);
            patch(ax, [years fliplr(years)], [lo' fliplr(hi')], COL(k,:), ...
                  'FaceAlpha', 0.15, 'EdgeColor','none', 'HandleVisibility','off');
        end
        lw = 1.4; if k == CLASS_TRAPPED; lw = 2.2; end
        h(k) = plot(ax, years, med(:,k), '-', 'Color', COL(k,:), 'LineWidth', lw);
    end
    ylabel(ax, 'share of agricultural decisions');
    title(ax, ttl, 'FontWeight','bold', 'FontSize', 10);
    grid(ax,'on'); ax.GridAlpha = 0.12;
    if iP == 1
        % Every plotted item appears in the legend; the ribbon is described in
        % the caption line below rather than duplicated as five legend entries.
        legend(ax, h, LBL, 'Location','northoutside', 'Orientation','horizontal', ...
               'NumColumns', 3, 'Box','off', 'FontSize', 8);
    else
        xlabel(ax, 'year');
    end
end

% SHARED x AND y. linkaxes ties both; the y limit is set from the pooled data
% so neither panel is clipped and the height difference is the comparison.
linkaxes(axes_, 'xy');
allMed = [median(nat,3,'omitnan'); median(gs,3,'omitnan')];
ylim(axes_(1), [0 min(1, 1.08*max(allMed(:)))]);
xlim(axes_(1), [years(1) years(end)]);

ribbonTxt = '';
if opt.Ensemble && size(nat,3) > 2; ribbonTxt = ', shaded 5-95% across runs'; end
title(tl, sprintf(['Aspiration/ability composition of agricultural agent decisions, ' ...
                   '%d runs (median%s)'], nUsed, ribbonTxt), ...
      'FontWeight','bold', 'FontSize', 11);

png = fullfile(runDir, char(opt.PngName));
exportgraphics(f, png, 'Resolution', 200);
fprintf('Wrote %s\n', png);

% ---------------------------------------------------------------- readout
T = table(years(:), median(nat(:,CLASS_TRAPPED,:),3,'omitnan'), ...
                    median(gs(:,CLASS_TRAPPED,:), 3,'omitnan'), ...
          'VariableNames', {'year','trapped_national','trapped_grandSud'});
fprintf('\nTrapped share of agricultural decisions (median across runs):\n');
fprintf('  national  mean %.3f   range %.3f-%.3f\n', ...
        mean(T.trapped_national,'omitnan'), min(T.trapped_national), max(T.trapped_national));
fprintf('  Grand Sud mean %.3f   range %.3f-%.3f\n', ...
        mean(T.trapped_grandSud,'omitnan'), min(T.trapped_grandSud), max(T.trapped_grandSud));
r = mean(T.trapped_grandSud,'omitnan') / max(mean(T.trapped_national,'omitnan'), eps);
fprintf('  Grand Sud / national = %.2fx\n', r);
if r < 1.1
    fprintf(2, ['\nThe two are within 10%%. Either the Grand Sud is not more ' ...
                'constrained than\nthe rest of the country in this ensemble, or ' ...
                'the regional signal is being\nswamped -- worth checking before ' ...
                'the contrast is claimed in the text.\n']);
end
end
