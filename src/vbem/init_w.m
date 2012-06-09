function w = init_w(x, u, varargin)
	% w = init_w(x, u, varargin)
	%
    % Initialization of the posterior parameters w for a trace
    % with datapoints x. Parameters are drawn from the prior and
    % optionally refined using hard and/or soft kmeans estimation.
    %
    % Inputs
    % ------
    % 
    % x : (T x D)
    %   Signal to learn posterior from.
    %
    % u : struct
    %   Hyperparameters for VBEM/HMI algorithm
    %
    %
    % Variable Inputs
    % ---------------
    %
    % hard_kmeans : boolean (default: false)
    %   Run hard kmeans algorithm 
    %
    % soft_kmeans : boolean (default: false)
    %   Run soft kmeans (gmdistribution.fit)
    %
    % threshold : float (default: 1e-5)
    %   Tolerance when running gmdistribution.fit
    %
    % quiet : boolean (default: true)
    %   Suppress gmdistribution.fit convergence warnings
    %
    %
    % Outputs
    % -------
    %
    % u : struct
    %   Hyperparameters with sampled state means
    %
    % Jan-Willem van de Meent
    % $Revision: 1.0$  $Date: 2011/02/14$

    % parse inputs
    ip = inputParser();
    ip.StructExpand = true;
    ip.addRequired('x', @isnumeric);
    ip.addRequired('u', @isstruct);
    ip.addParamValue('hard_kmeans', false, @isscalar);
    ip.addParamValue('soft_kmeans', false, @isscalar);
    ip.addParamValue('threshold', 1e-5, @isscalar);
    ip.addParamValue('quiet', true, @isscalar);
    ip.parse(x, u, varargin{:});
    args = ip.Results;
    x = args.x;
    u = args.u;
    K = length(u.mu);
    T = size(x, 1);
    D = size(x, 2);

    % this is necessary just so matlab does not complain about 
    % structs being dissimilar because of the order of the fields
    w = u;

    % initialize first guess from prior parameters
    % draw mixture weights from dirichlet
    theta.pi = dirrnd(u.pi(:)', 1)';

    for k = 1:K
        % draw precision matrix from wishart
        Lambda = wishrnd(u.W(k, :, :), u.nu(k));
        theta.Lambda(k,:,:) = Lambda;
        % draw mu from multivariate normal
        theta.mu(k, :) = mvnrnd(u.mu(k, :), inv(u.beta(k) * Lambda));
    end

    % refine centers using hard kmeans
    if args.hard_kmeans
        % run hard kmeans to get cluster centres
        if K > 1
            [idxs mu] = kmeans(x, K, 'Start', theta.mu);
        else
            idxs = ones(length(x), 1);
        end
        % estimate weight, mean and std dev
        for k = 1:K
            msk = (idxs == k);
            p = sum(msk) / T;
            mu = mean(x(msk), 1);
            dx = bsxfun(@minus, x, mu);
            dx2 = bsxfun(@times, dx, reshape(dx, [length(msk), 1 D]));
            Sigma = squeeze(mean(dx2, 1)) + 1e-6 * (sum(msk) == 1);

            theta.pi(k) = p;
            theta.mu(k, :) = mu;
            theta.Lambda(k, :, :) = inv(Sigma);
        end
    end
    
    % refine centers using a gaussian mixture model (soft kmeans)
    if args.soft_kmeans
        % if K > 1
        %     % specify initial parameter values as gmdistribution struct
        %     gmm0.PComponents = theta0.pi(:)';
        %     gmm0.mu = theta0.mu;
        %     gmm0.Sigma = theta0.Sigma;        

        %     % silence convergence warnings
        %     if args.quiet
        %         warn = warning('off', 'stats:gmdistribution:FailedToConverge');
        %     end
        
        %     % run soft kmeans
        %     gmm = gmdistribution.fit(x, K, 'Start', gmm0, ...
        %                              'CovType', 'diagonal', 'Regularize', 1e-6, ...
        %                              'Options', struct('Tolerance', args.threshold));

        %     % unsilence convergence warnings
        %     if args.quiet
        %         warning(warn);
        %     end
        % else
        %     gmm = gmdistribution.fit(x, 1, 'Regularize', 1e-6, ...
        %                              'Options', struct('Tolerance', args.threshold));
        % end
        
        % if all(isfield(gmm, {'PComponents', 'mu', 'Sigma'}))
        %     theta0.pi = gmm.PComponents(:);
        %     theta0.mu = gmm.mu;
        %     theta0.Sigma = gmm.Sigma;                  
        % end

        % silence convergence warnings
        if args.quiet
            warn = warning('off', 'gmm_map:joint_decreased');
        end

        % run map EM
        [theta_km, L] = gmm_map(x, theta, u);

        % unsilence convergence warnings
        if args.quiet
            warning(warn);
        end

        % check for bad run
        if (length(L) > 1) & (L(end) > L(1))
            theta = theta_km;
        else
            warning('init_w:gmm_map_not_converged', ...
                    'soft kmeans step did not converge');
        end
    end

    % draw transition matrix from dirichlet
    theta.A = dirrnd(u.A);

    % add pi to prior with count 1
    w.pi = u.pi + theta.pi;

    % add draw A ~ Dir(u.A) to prior with count (T-1)/K for each row  
    w.A = u.A + theta.A .* (T-1) ./ K;

    % add T/K counts to beta and nu
    w.beta = u.beta + T/K;
    w.nu = w.beta + 1;

    for k = 1:K
        w.mu(k, :) = (u.beta(k) * u.mu(k, :) + T/K * theta.mu(k,:)) / w.beta(k);;
    end

    % set W such that W nu = L 
    % TODO: this should be a proper update, but ok for now
    w.W = bsxfun(@times, theta.Lambda, 1 ./ w.nu);