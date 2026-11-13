function out = make_drought_workflow_figure(varargin)
% make_drought_workflow_figure  --  the four-panel drought module figure
%
%   make_drought_workflow_figure                     % full quality, slow
%   make_drought_workflow_figure('NReal', 20)        % quick layout pass
%   make_drought_workflow_figure('SSP', 'SSP2')
%
% WHAT IT ASSEMBLES
%   (a) make_scenario_trend_panel     GRMA secular trajectory, SSP2 vs SSP5,
%                                     national and Grand Sud
%   (b) make_divergence_map_panel     where the two scenarios separate
%   (c) make_drought_state_panel      observed and synthetic drought states
%   (d) make_drought_module_figure    the resulting yield series for one region
%
% THE ARGUMENT THE FIGURE MAKES, IN ORDER
% (a) says the scenario signal is small nationally and concentrated
% regionally. (b) says where. (c) says how interannual variability is
% generated once the observed record runs out, and shows the observed half
% beside the synthetic half so the copula claim can be judged. (d) says what
% comes out the other end: a single region's yield factor with both regimes
% and the floors visible.
%
% LAYOUT
% Three wide panels stacked on the left, the map spanning the full height on
% the right. Madagascar's bounding box is roughly 1:2 once the longitude
% correction is applied, so a full-height column suits it and a 2x2 grid does
% not -- in a 2x2 the map either shrinks to a third of the available area or
% forces the whole row taller than the time series need.
%
% SHARED Y LIMITS ON (a) AND (d)
% Both plot a yield factor, and the composite exists partly so a reader can
% weigh interannual variability against the secular trend. If the two panels
% auto-scaled independently that comparison would be silently wrong, so the
% same YLim is passed to both from here rather than set inside either.
%
% COST
% (c) runs createUtilityLayers once; (d) runs it NReal times. At the default
% NReal = 100 the figure takes several minutes. Drop to 20 while iterating on
% layout -- the ensemble mean gets rougher but nothing moves on the page.
%
% REPRODUCIBILITY
% Both stochastic panels seed themselves: (c) calls rng(Seed) once, and (d)
% calls rng(r) at the top of each realisation. Neither inherits RNG state, so
% running them in this order gives the same figure as running either alone,
% and the assembler does not need to seed anything.

p = inputParser;
addParameter(p, 'SSP',      'SSP5');   % the scenario panels (c) and (d) show
addParameter(p, 'EndYear',  2085);
addParameter(p, 'Year',     2085);     % the year panel (b) maps
addParameter(p, 'Region',   19);       % panel (d): 19 = Androy
addParameter(p, 'NReal',    100);
addParameter(p, 'NShow',    6);
addParameter(p, 'DroughtScaleFactor', 0.30);
addParameter(p, 'Seed',     1);        % panel (c) realisation
addParameter(p, 'South',    {'Androy', 'Anosy', 'Atsimo-Andrefana'});
addParameter(p, 'YLim',     [0 1.05]);
addParameter(p, 'OutFile',  './Outputs/fig_drought_workflow.png');
addParameter(p, 'Resolution', 220);
parse(p, varargin{:});
opt = p.Results;

addpath('./Override_Core_MIDAS_Code');
addpath('./Application_Specific_MIDAS_Code');
addpath('./Core_MIDAS_Code');

if ~exist('./Outputs', 'dir'); mkdir('./Outputs'); end

fig = figure('Position', [60 40 1500 1250], 'Color', 'w');
T = tiledlayout(fig, 3, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

% ---- (b) first, because it spans and must claim its tiles before the -----
%      left column consumes them by index.
axB = nexttile(T, 2, [3 1]);

axA = nexttile(T, 1);
axC = nexttile(T, 3);
axD = nexttile(T, 5);

% ---- (a) ----------------------------------------------------------------
fprintf('\n================ panel (a): scenario trend ================\n');
outA = make_scenario_trend_panel('Axes', axA, 'Standalone', false, ...
                                 'EndYear', opt.EndYear, 'South', opt.South, ...
                                 'YLim', opt.YLim);

% ---- (b) ----------------------------------------------------------------
% Labels 'south' rather than 'all': 22 values are legible standalone and are
% not at this size. The full table prints to the console for the caption.
fprintf('\n================ panel (b): divergence map ================\n');
outB = make_divergence_map_panel('Axes', axB, 'Standalone', false, ...
                                 'Year', opt.Year, 'South', opt.South, ...
                                 'Labels', 'south');

% ---- (c) ----------------------------------------------------------------
fprintf('\n================ panel (c): drought states ================\n');
outC = make_drought_state_panel('Axes', axC, 'SSP', opt.SSP, ...
                                'EndYear', opt.EndYear, 'Seed', opt.Seed, ...
                                'South', opt.South, ...
                                'LegendLocation', 'southoutside');

% ---- (d) ----------------------------------------------------------------
fprintf('\n================ panel (d): yield realisations ================\n');
make_drought_module_figure('Axes', axD, 'Standalone', false, ...
                           'Region', opt.Region, 'SSP', opt.SSP, ...
                           'EndYear', opt.EndYear, 'NReal', opt.NReal, ...
                           'NShow', opt.NShow, 'YLim', opt.YLim, ...
                           'DroughtScaleFactor', opt.DroughtScaleFactor);

% ---- panel letters ------------------------------------------------------
% Drawn in normalized axes units above each axes, so they track the tile
% wherever the layout puts it. annotation() would need figure coordinates and
% would drift the moment the figure is resized.
letterAxes(axA, '(a)');
letterAxes(axB, '(b)');
letterAxes(axC, '(c)');
letterAxes(axD, '(d)');

% Panel titles carry the detail; the layout title says only what the figure
% is, per the rule that a title states the data rather than the inference.
title(T, sprintf(['Drought module: scenario trajectory, spatial divergence, ' ...
                  'state sequence and resulting yield factor (%s)'], opt.SSP), ...
      'FontWeight', 'normal', 'FontSize', 13);

exportgraphics(fig, opt.OutFile, 'Resolution', opt.Resolution);
fprintf('\nWrote %s\n', opt.OutFile);

out = struct('figure', fig, 'layout', T, ...
             'axes', struct('a', axA, 'b', axB, 'c', axC, 'd', axD), ...
             'panelA', outA, 'panelB', outB, 'panelC', outC);
end

% =========================================================================
function letterAxes(ax, txt)
t = text(ax, -0.02, 1.045, txt, 'Units', 'normalized', ...
         'FontWeight', 'bold', 'FontSize', 13, ...
         'HorizontalAlignment', 'right', 'VerticalAlignment', 'bottom');
t.HandleVisibility = 'off';   % keep it out of any legend on that axes
end
