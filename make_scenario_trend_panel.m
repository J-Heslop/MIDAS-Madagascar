function out = make_scenario_trend_panel(varargin)
% make_scenario_trend_panel  --  panel (a) of the drought workflow figure
%
%   make_scenario_trend_panel
%   make_scenario_trend_panel('OutFile', './Outputs/p_a.png')
%
% WHAT IT SHOWS
% The GRMA secular yield trajectory under SSP2-4.5 and SSP5-8.5, plotted twice:
% averaged over all 22 regions, and averaged over the three Grand Sud regions
% (Androy, Anosy, Atsimo-Andrefana).
%
% THE QUANTITY IS agYF, NOT A FLAT CROP AVERAGE
% Each region's value is the mean over the agricultural layers it actually
% has, via grmaLayerMeanYield -- the same construction createUtilityLayers
% uses. Rice is restricted to two disjoint region sets; the Grand Sud has
% maize and cassava only. See that function's header for why a uniform
% three-crop average is the wrong quantity here.
%
% WHY BOTH EXTENTS
% Nationally the two scenarios are nearly indistinguishable -- Supplemental
% 2.4.2 reports differences below 0.03 at 2085, and the layer-aware national
% gap is 0.021. In the Grand Sud they separate substantially: 0.066, i.e.
% 3.19x the national gap, driven by Androy at 0.103.
%
% One qualification the divergence map makes unavoidable: Betsiboka (0.047),
% Sofia (0.043) and Boeny (0.036) are north-western and sit inside the range
% spanned by Atsimo-Andrefana (0.049) and Anosy (0.045). The signal is dry
% west AND south, with Androy exceptional -- not southern alone.
%
% Plotting the national pair alone would show the "scenarios barely differ"
% result and quietly contradict the regional analysis that follows. Plotting
% both makes the CONTRAST the message: the scenario signal exists, and it is
% concentrated exactly where drought-driven migration is expected to
% originate. This panel therefore sets up the divergence map rather than
% arguing against it.
%
% NO MODEL CALL
% This reads the GRMA yield CSVs directly. The surfaces are inputs, not model
% outputs, so nothing here depends on the state of the codebase -- which also
% means the panel is unaffected by the drought-module changes of 2026-09-03.
%
% SHAPE OF THE SERIES
% Flat at the baseline value from 1985 to 2025, then piecewise linear through
% the 2050 and 2085 anchors (verified: -0.0046/yr then -0.0027/yr for Androy
% maize under SSP5). The baseline represents 1985-2025 mean conditions, so the
% flat section is not an assertion that nothing happened before 2025 -- it is
% the absence of a resolved trend in the source data.

p = inputParser;
addParameter(p, 'South',    {'Androy', 'Anosy', 'Atsimo-Andrefana'});
addParameter(p, 'DataDir',  './Data');
addParameter(p, 'LayerFile', './Data/utility_layers_v1.csv');
addParameter(p, 'EndYear',  2085);
addParameter(p, 'OutFile',  './Outputs/fig_panel_a_scenario_trend.png');
addParameter(p, 'Standalone', true);   % false when called by the assembler
% ShadeGaps: shade the SSP2-SSP5 range for BOTH extents (each legended) and
% suppress the data labels. Default false -- the labels carry the same
% information with less ink, and shading only one extent would imply the other
% gap does not matter.
addParameter(p, 'ShadeGaps', false);
% Extend past the last data year so the 2085 labels are not clipped.
addParameter(p, 'XMax', 2095);
% Y LIMITS. Fixed at [0 1] rather than auto-scaled, for two reasons.
%
% The yield factor is a bounded proportion: 0 is total crop failure and 1 is
% no drought effect, so both ends carry meaning and the full range is the
% natural frame. Auto-scaling lands on roughly [0.5 0.9] here, which makes the
% SSP2-SSP5 gaps look far larger than they are -- the southern gap is 0.066,
% about 5% of the true range. The data labels carry the magnitudes; the
% divergence MAP is where the gaps are properly displayed.
%
% More practically, this panel sits beside the drought-module panel in the
% composite figure, and that one must show yield floors at 0.15-0.30. If the
% two panels carry different y-scales a reader will misjudge the size of
% inter-annual variability against the secular trend, which is the comparison
% the composite exists to support. Pass the SAME YLim to both from the
% assembler so they cannot drift apart.
%
% An axis break was considered and rejected: breaks are easy to misread, are
% discouraged by most style guides, and behave unpredictably when panels are
% composited or rescaled.
addParameter(p, 'YLim', [0 1]);
addParameter(p, 'Axes',     []);
parse(p, varargin{:});
opt = p.Results;

SSPS = {'SSP2', 'SSP5'};
COL  = containers.Map(SSPS, {[0.20 0.40 0.70], [0.75 0.25 0.15]});

% ---- read the surfaces --------------------------------------------------
% LAYER-AWARE (2026-09-03). This block used to average rice, maize and
% cassava uniformly in every region. utility_layers_v1.csv gives rice to two
% disjoint region sets and to nobody else, so eight regions -- including all
% three Grand Sud regions -- have maize and cassava only. The old average
% therefore plotted rice yields where the model has no rice layer, and did so
% most wrongly in exactly the regions this panel exists to characterise.
%
% grmaLayerMeanYield reproduces the agYF construction from
% createUtilityLayers. The divergence map (panel b) calls the same function,
% so the two panels report the same quantity and cannot drift apart.
%
% Effect on the headline number: the Grand Sud 2085 gap widens from 0.046 to
% 0.066 against a national 0.021, i.e. 3.19x rather than 2.6x. The southern
% divergence result gets stronger, not weaker.
SOUTH = string(opt.South);
nat = struct(); sth = struct(); yearsOut = []; nLayersSouth = [];
for iS = 1:numel(SSPS)
    ssp = SSPS{iS};
    [Y, regNames, yrs, info] = grmaLayerMeanYield(ssp, ...
        'DataDir', opt.DataDir, 'LayerFile', opt.LayerFile, 'EndYear', opt.EndYear);
    if isempty(yearsOut); yearsOut = yrs; end

    % Exact, case-sensitive match, as createUtilityLayers resolves
    % restrict_to. Case-folding here would hide a genuine name mismatch.
    isSouth = ismember(regNames, SOUTH);
    if sum(isSouth) ~= numel(SOUTH)
        error('make_scenario_trend_panel:southUnmatched', ...
              ['%d of %d southern regions matched. Unmatched: %s. ' ...
               'Available: %s'], sum(isSouth), numel(SOUTH), ...
              strjoin(cellstr(setdiff(SOUTH, regNames)), ', '), ...
              strjoin(cellstr(regNames), ', '));
    end
    nat.(ssp) = mean(Y, 1, 'omitnan');
    sth.(ssp) = mean(Y(isSouth, :), 1, 'omitnan');
    nLayersSouth = info.nLayersPerRegion(isSouth);
end

% ---- plot ---------------------------------------------------------------
if isempty(opt.Axes)
    fig = figure('Position', [100 100 980 500], 'Color', 'w');
    ax  = axes(fig);
else
    ax = opt.Axes;
end
hold(ax, 'on'); box(ax, 'on');

% GAP SHADING. Off by default. The endpoint gaps are stated as data labels
% below, so shading them as well double-encodes the same quantity. Shading one
% extent and not the other -- as an earlier version did -- is worse still,
% because it implies the unshaded gap is not worth attention. Set ShadeGaps
% true to draw BOTH, each with its own legend entry, and drop the labels.
if opt.ShadeGaps
    patch(ax, [yearsOut fliplr(yearsOut)], [sth.SSP2 fliplr(sth.SSP5)], ...
          [0.80 0.35 0.25], 'FaceAlpha', 0.18, 'EdgeColor', 'none', ...
          'DisplayName', 'SSP2-SSP5 range, Grand Sud');
    patch(ax, [yearsOut fliplr(yearsOut)], [nat.SSP2 fliplr(nat.SSP5)], ...
          [0.35 0.45 0.70], 'FaceAlpha', 0.18, 'EdgeColor', 'none', ...
          'DisplayName', 'SSP2-SSP5 range, national');
end

for iS = 1:numel(SSPS)
    ssp = SSPS{iS};
    plot(ax, yearsOut, nat.(ssp), '--', 'Color', COL(ssp), 'LineWidth', 1.5, ...
         'DisplayName', sprintf('%s, national mean', ssp));
    plot(ax, yearsOut, sth.(ssp), '-',  'Color', COL(ssp), 'LineWidth', 2.2, ...
         'DisplayName', sprintf('%s, Grand Sud', ssp));
end

% ANCHOR MARKERS. GRMA supplies three values per region -- a 1985-2025
% baseline, 2050 and 2085 -- and everything between is linear interpolation.
% Marking them shows the reader how few real datapoints underlie the curves,
% which vertical gridlines at those years would not convey: a line at 2050
% implies something happens there, whereas the point is that nothing does
% except the arrival of a data value.
anchors = [2025 2050 2085];
anchors = anchors(anchors <= opt.EndYear);
for iS = 1:numel(SSPS)
    ssp = SSPS{iS};
    for a = anchors
        k = find(yearsOut == a, 1);
        if isempty(k); continue; end
        plot(ax, a, nat.(ssp)(k), 'o', 'MarkerSize', 5, 'MarkerFaceColor', 'w', ...
             'MarkerEdgeColor', COL(ssp), 'LineWidth', 1.2, 'HandleVisibility', 'off');
        plot(ax, a, sth.(ssp)(k), 'o', 'MarkerSize', 6, 'MarkerFaceColor', COL(ssp), ...
             'MarkerEdgeColor', COL(ssp), 'HandleVisibility', 'off');
    end
end

% DATA LABELS, coloured by scenario. At 2025 the two scenarios are identical
% by construction -- they share the GRMA baseline -- so that anchor is
% labelled once in grey rather than twice in two colours, which would imply a
% difference that does not exist.
if ~opt.ShadeGaps
    for a = anchors
        k = find(yearsOut == a, 1);
        if isempty(k); continue; end
        same = abs(nat.SSP2(k) - nat.SSP5(k)) < 5e-4;
        if same
            text(ax, a, nat.SSP2(k), sprintf(' %.2f', nat.SSP2(k)), 'FontSize', 9, ...
                 'Color', [0.35 0.35 0.35], 'VerticalAlignment', 'bottom');
            text(ax, a, sth.SSP2(k), sprintf(' %.2f', sth.SSP2(k)), 'FontSize', 9, ...
                 'Color', [0.35 0.35 0.35], 'VerticalAlignment', 'bottom');
        else
            % Offset the pair vertically so the two scenario labels do not
            % collide where the curves are close together.
            for iS = 1:numel(SSPS)
                ssp = SSPS{iS};
                vaN = 'bottom'; vaS = 'bottom';
                if nat.(ssp)(k) < nat.(SSPS{3 - iS})(k); vaN = 'top'; end
                if sth.(ssp)(k) < sth.(SSPS{3 - iS})(k); vaS = 'top'; end
                if a == 2050 && iS == 2;
                    text(ax, a, nat.(ssp)(k), sprintf(' %.2f', nat.(ssp)(k)), ...
                         'FontSize', 9, 'Color', COL(ssp), 'VerticalAlignment', vaN,...
                         'HorizontalAlignment','right');
                    text(ax, a, sth.(ssp)(k), sprintf(' %.2f', sth.(ssp)(k)), ...
                         'FontSize', 9, 'Color', COL(ssp), 'VerticalAlignment', vaS,...
                         'HorizontalAlignment','right');
                else 
                    text(ax, a, nat.(ssp)(k), sprintf(' %.2f', nat.(ssp)(k)), ...
                         'FontSize', 9, 'Color', COL(ssp), 'VerticalAlignment', vaN);
                    text(ax, a, sth.(ssp)(k), sprintf(' %.2f', sth.(ssp)(k)), ...
                         'FontSize', 9, 'Color', COL(ssp), 'VerticalAlignment', vaS);
                end 
            end
        end
    end
end

xline(ax, 2025, ':', 'baseline ends (2025)', 'Color', [0.5 0.5 0.5], ...
      'FontSize', 9, 'LabelVerticalAlignment', 'bottom', ...
      'LabelHorizontalAlignment', 'left', 'HandleVisibility', 'off');

xlabel(ax, 'year'); ylabel(ax, 'GRMA yield factor');
title(ax, ['Projected crop yield factor, mean of the agricultural layers ' ...
           'present in each region: national mean and Grand Sud'], ...
      'FontWeight', 'normal');
legend(ax, 'show', 'Location', 'southwest', 'Box', 'off', 'FontSize', 9);
xlim(ax, [1985 opt.XMax]);
if ~isempty(opt.YLim); ylim(ax, opt.YLim); end

% RIGHT-HAND TICK LABELS. A transparent overlay axes rather than yyaxis,
% which recolours the rulers and would interfere with the legend. Created
% last so it sits above nothing and captures no plotted objects.
%
% STANDALONE ONLY. The overlay is positioned by copying ax.Position, which
% requires ax to own its position. Inside a tiledlayout the parent manages
% position and the copy is either rejected or immediately overridden, leaving
% a stray empty axes floating over the composite. The assembler does not need
% the right-hand ticks anyway -- panels sit adjacent there, so the left ruler
% of the neighbouring panel does the same job.
if isempty(opt.Axes)
    drawnow;
    axR = axes('Parent', ax.Parent, 'Position', ax.Position, 'Color', 'none', ...
               'YAxisLocation', 'right', 'XTick', [], 'Box', 'off', ...
               'YLim', ax.YLim, 'YTick', ax.YTick, 'XLim', ax.XLim, ...
               'HitTest', 'off', 'HandleVisibility', 'off');
    axR.XAxis.Visible = 'off';
    linkaxes([ax axR], 'y');
end

gN = nat.SSP2(end) - nat.SSP5(end);
gS = sth.SSP2(end) - sth.SSP5(end);

if opt.Standalone && isempty(opt.Axes)
    exportgraphics(fig, opt.OutFile, 'Resolution', 200);
    fprintf('Wrote %s\n', opt.OutFile);
end

% ---- numbers for the caption -------------------------------------------
fprintf('\n--- panel (a) ---\n');
fprintf(['quantity: mean GRMA yield factor over the ag layers present in each ' ...
         'region (agYF secular component)\n']);
fprintf('Grand Sud regions carry %s ag layer(s) each\n', ...
        strjoin(cellstr(string(unique(nLayersSouth))), '/'));
fprintf('%-12s %8s %8s %8s\n', 'extent', '1985', '2085 S2', '2085 S5');
fprintf('%-12s %8.3f %8.3f %8.3f   gap %.3f\n', 'national', ...
        nat.SSP2(1), nat.SSP2(end), nat.SSP5(end), gN);
fprintf('%-12s %8.3f %8.3f %8.3f   gap %.3f\n', 'Grand Sud', ...
        sth.SSP2(1), sth.SSP2(end), sth.SSP5(end), gS);
fprintf('southern gap is %.1fx the national gap\n', gS / max(gN, eps));

out = struct('years', yearsOut, 'national', nat, 'south', sth, ...
             'gapNational', gN, 'gapSouth', gS);
end
