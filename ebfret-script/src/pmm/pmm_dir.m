function [u, g, L, exitflag] = pmm_dir(Xi, u0, pi0, varargin)
	% [u, g, L, exitflag] = pmm_dir(Xi, u0, pi0, varargin)
	%
	% Mixture model for Dirichlet priors.  
	%
	% Inputs
	% ------
	%
	% 	Xi : (N x D) or (N x E x D)
	%		Posterior pseudo-counts for each sample 
	%
	%	u0 : (K x D) or (K x E x D) 
	%		Initial guess for set of prior parameters for each 
	%       mixture component.
	%
	%	pi0 : (K x 1)
	%		Initial guess for mixture weights
	%
	% Variable Inputs
	% ---------------
	%
	%	max_iter : int (default: 100)
	%		Maximum number of iterations
	%
	%	threshold : double (default: 1e-5)
	%		Convergence threshold
	%	
	% Outputs
	% -------
	%
	%  u : (K x D) or (K x E x D) 
	%		Prior parameters for each mixture component
	%
	%  g : (N x K)
	%		Responsibilities
	%
	%  L : (I x 1)
	%		Log likelihood for each iteration
	%
	%	exitflag : int
	%		Info about result of optimization
	%			
	%			1  : Converged
	%			0  : Hit maximum number of iterations
	%		    -1 : Likelihood decreased on last iteration
	%		    -2 : Failed on first iteration
	%
	% TODO: write up math and document this properly

	% parse inputs
	ip = inputParser();
	ip.StructExpand = true;
	ip.addRequired('Xi', @isnumeric);
	ip.addRequired('u0', @isnumeric);
	ip.addRequired('pi0', @isnumeric);
	ip.addParamValue('threshold', 1e-5, @isscalar);
	ip.addParamValue('max_iter', 100, @isscalar);
	ip.parse(Xi, u0, pi0, varargin{:});

	% collect inputs
	args = ip.Results;
	Xi = args.Xi;
	u0 = args.u0;
	pi0 = args.pi0;

	% print debug output
	Debug = false;

	% get dimensions
	[K] = size(u0, 1);
	if ndims(Xi) == 3
		[N E D] = size(Xi);
	else
		[N D] = size(Xi);
		E = 1;
		% insert empty dim
		Xi = reshape(Xi, [N E D]);
		u0 = reshape(u0, [K E D]);
	end

	% replace zeros in initial guess with a small number
	u0(u0 == 0) = eps;

 	% set up for first iteration
	L = [-inf];
	it = 1;
	p_new = pi0(:);
	u_new = u0;
	exitflag = 1;

	% iterate EM steps until log likelihood L converges
	while (it == 1) | ...
		  (((L(it) - L(it-1)) > args.threshold * abs(L(it))) ...
		   & (it < args.max_iter))
		if it > 1
			fprintf('[debug] it: %d  1 - L(it-1)/L(it): %.2e\n', it, 1 - L(it-1)/L(it));
		end

		% E-step: calculate responsibilities

		% calculate log of p(w(n,:) | u(k,:), z=k) = Beta(w) / Beta(u)
		w_new = bsxfun(@plus, reshape(Xi, [N 1 E D]), ...
		                      reshape(u_new, [1 K E D]));
		log_Bw = sum(gammaln(w_new), 4) - gammaln(sum(w_new, 4));
		log_Bu = sum(gammaln(u_new), 3) - gammaln(sum(u_new, 3));
		log_pw_uz = sum(bsxfun(@minus, reshape(log_Bw, [N K E]), ... 
		                               reshape(log_Bu, [1 K E])), 3);

		% calculate gamma(n, k) = p(z(n)=k | w(n, :), u)
		% to avoid underflow, we renormalize the probabilities 
		% by their mean value across k for each n
		log_pw_uz0 = bsxfun(@minus, log_pw_uz, mean(log_pw_uz, 2));
		pw_uz0 = exp(log_pw_uz0);
		pwz_u0 = bsxfun(@times, pw_uz0, p_new');
		g_new = bsxfun(@rdivide, pwz_u0, sum(pwz_u0, 2)); 

		% Check whether log likelihood increased
		L_new = sum(sum(g_new .* log_pw_uz, 2));
		if L_new > L(it)
			L(it+1) = L_new;
			u = u_new;
			g = g_new;
			p = p_new;
		elseif L(it) - L_new > args.threshold * abs(L_new)
			warning('pmm_dir:DecreasedL', 'Log likelihood decreased by %e', L_new-L(it))
			% set exitflag to likelihood decrease on last iter
			exitflag = -1;
			break;
		else
			if (it ==1)
				% set exitflag to first iteration failed
				exitflag = -2;
				% make sure output values assigned (so we can fail gracefully)
				u = u_new;
				g = g_new;
				p = p_new;
			end
			break;
		end

		% M-step: update u and p
		%
		% Updates work out to solving K systems of D equations:
		%
		% psi(sum_d u(k,d)) - psi(u(k,d))
		%   =  1/N_k Sum_n g(n, k) (psi(sum_d w(n,k,d)) - psi(w(n,k,d))) 
		%
		% note that the expression in the left hand side is
		% equivalent to the log expectation value of the parameter
		% under the prior (up to a sign)
		%
		% E_u[log theta] = int d theta log(theta) p(theta | u)
		%                = - (psi(sum_d u(k,d)) - psi(u(k,d)))
		%
		% Thus the updates amount to ensuring the log expectation
		% value of theta under the prior for cluster k is equal to 
		% the log expectation under the posterior, averaged over all 
		% samples in the cluster
		 
		% normalize gamma
		g0 = bsxfun(@rdivide, g, sum(g, 1));
		
		% sum Xi over d coordinate 
		Xi0 = sum(Xi, 3);

		% set optimization settings
		opts = optimset('display', 'off', ...
		                'tolX', 1e-2 * args.threshold, ...
		                'tolFun', eps);

		% solve u for each mixture component
		for k = 1:K
			for e = 1:E
				% solve for each d separately until convergence
				u_ke = eps * ones(size(u_new(k,e,:)));
				jt = 1;
				kl = zeros(args.max_iter, 1);
				kl(1) = kl_dir(u_new(k,e,:), u_ke);
				while (jt == 1) | ...
					  ((abs(kl(jt-1) - kl(jt)) > 1e2 * args.threshold * kl(jt)) ...
					   & (jt < args.max_iter))
					u_ke_prev = u_new(k,e,:);
					for d = 1:D
						% sum u over all indices except d
						u_ke0 = sum(squeeze(u_new(k,e,:)) .* (d ~= 1:D)');;
						% set root functions for this iteration
						root_fun_ked = ...
						    @(u) root_fun(u, u_ke0, ...
						                  Xi(:,e,d), Xi0(:,e), ...
						                  g0(:,k));
						% solve for component d						                             
						u_new(k, e, d) = ...
						    lsqnonlin(root_fun_ked, ... 
						    	      u_new(k,e,d), 0, Inf, opts);
					end
					kl(jt+1) = kl_dir(u_new(k,e,:), u_ke_prev);
					jt = jt+1;
				end
				fprintf('[debug] it: %d k: %d e: %d jt: %d\n', it, k, e, jt)
			end
			squeeze(u_new(k,:,:));
		end

		% update for p
		p_new = (sum(g, 1) ./ sum(g(:)))';

		% print debug output
		if Debug
			for k = 1:K
				fprintf('%i, %i\n', it , k)
				for e = 1:e
					fprintf('%s\n', sprintf('04%.1e   ', u_new(k,e,:)));
				end
			end
		end

		% increase iteration count
		it = it +1;

		% if maximum iterations hit, set exitflag
		if (it == args.max_iter)
			exitflag = 0;
		end
	end

function err = root_fun(u_ked, u_ke0, Xi_ed, Xi_e0, g0_k)
	% Root function for u update in M-step
	%
	% Inputs
    % ------
    %	
    %   u_ked : 1 x 1
    %	u_ke0 : 1 x 1 
    %	Xi_ed : N x 1 
    %	Xi_0 : N x 1
    % 	g0_k : N x 1
    %
    % Outputs
    % -------
    % 
    %	err : 1 x 1

	% calculate expectation of theta under posterior params
	Ew_log_theta = psi(Xi_ed + u_ked) - psi(Xi_e0 + u_ke0 + u_ked);
	% average over samples, weighted by responsibilities
	% to obtain estimate of log(theta) for cluster
	Ew_log_theta = sum(g0_k .* Ew_log_theta, 1);
	% calculate expectation of theta under posterior params
	Eu_log_theta = psi(u_ked) - psi(u_ke0 + u_ked);
	% calculate solver error
	err = (Eu_log_theta - Ew_log_theta);