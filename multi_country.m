% see MATLAB Tutorial on how to run CUDA or PTX Code on GPU:
% http://www.mathworks.com/help/distcomp/run-cuda-or-ptx-code-on-gpu.html
clear
gpu = true; max_iter=10000; disp_iter=100;
N     = 10;      % Number of countries
gam   = 1;      % Utility-function parameter
alpha = 0.36;   % Capital share in output
beta  = 0.99;   % Discount factor
delta = 0.025;  % Depreciation rate 
rho   = 0.95;   % Persistence of the log of the productivity level
Sigma = 0.01^2*(eye(N)+ones(N)); % Covariance matrix of shocks to the log of the productivity level
A=(1/beta-1+delta)/alpha; D=2*N;
mu = [repmat(3,1,N) repmat(2,1,N)]; % States: k[1..N], a[1..N]
if any(size(mu)~=[1,D]); error('mu must be a row vector of length %d',D); end
gssa=false; % use initial guess from GSSA
if gssa
    addpath('Smolyak_Anisotropic_JMMV_2014')
    load(sprintf('gssa_N=%d.mat',N));
    xm=(min_simul+max_simul)/2; xs=(max_simul-min_simul)/2;
    clear min_simul max_simul
else
    xm=ones(1,D); xs=repmat(0.2,1,D); % set mean xm to steady state and spread xs to 20% away
end
[B,X,S]=smolyak(mu,xm,xs);
if gssa % to check with JMMV reorder rows using j indices
    [~,i]=sortrows(Smolyak_Elem_Anisotrop(Smolyak_Elem_Isotrop(D,max(mu)),mu));
    [~,j]=sortrows(S); [~,j]=sort(j); i=i(j); clear j
end

J=11;
if J>10
    [e,w]=monomial(N,Sigma,J-10); % M1 or M2 monomial rule
else
    [e,w]=gauher(J,Sigma); % Gauss-Hermite quadrature with J nodes
end
e=exp(e)';

J=size(e,2);
M=size(B,1);
L=M*J;

k=X(:,1:N); a=X(:,N+1:2*N); clear X
ap=reshape(bsxfun(@times,repmat(a.^rho,1,J),e(:)'),M,N,J);
x=[nan(L,N) reshape(permute(ap,[1 3 2]),L,N)];

if gpu
    gd = gpuDevice;
%     if system(sprintf('nvcc -arch=sm_35 -ptx smolyak_kernel.cu -DD=%d -DL=%d -DM=%d -DN=%d -DSMAX=%d -DMU_MAX=%d',D,L,M,N,2^max(mu),max(mu))); error('nvcc failed'); end
    kernel = parallel.gpu.CUDAKernel('smolyak_kernel.ptx', 'smolyak_kernel.cu');
    kernel.ThreadBlockSize = 128;
    kernel.GridSize = ceil(L/kernel.ThreadBlockSize(1));
    setConstantMemory(kernel,'xm',xm);
    setConstantMemory(kernel,'xs',xs);
    setConstantMemory(kernel,'s',uint8(S-1));
    kpp_=nan(L,N,'gpuArray');
    x=gpuArray(x);
    xm=gpuArray(xm);
    xs=gpuArray(xs);
else
    kpp=ones(M,N,J);
end
%% main loop
bfile=sprintf('b_N=%d_mu=%d.mat',N,max(mu));
if exist(bfile,'file')
    fprintf('loading %s\n',bfile)
    load(bfile)
elseif gssa
    b=smolyak(mu,0,1,S,simul_norm)\k_prime_GSSA;
else
    b=zeros(M,N); b(1,:)=1;
end
kp=B*b;
bdamp=0.05;
binvfile=sprintf('B_inv_N=%d_mu=%d.mat',N,max(mu));
if exist(binvfile,'file')
    fprintf('loading %s\n',binvfile)
    load(binvfile)
else
    B_inv=inv(B);
    save(binvfile,'B_inv')
end
if gpu
    B_inv=gpuArray(B_inv);
    b=gpuArray(b);
    % Measure the overhead introduced by calling the wait function.
    tover = inf;
    for itr = 1:100
        tic;
        wait(gd);
        tover = min(toc, tover);
    end
end
t1=0;
t3=0;
tic
for it=1:max_iter
    if any(kp(:)<0); error('negative capital'); end
    if it==10; bdamp=0.1; end
    if gpu
        x(:,1:N)=repmat(kp,J,1);
t0=tic;
        kpp_ = feval(kernel, x, kpp_, b);
        wait(gd);
t1=t1+toc(t0)-tover;
        kpp = gather(kpp_);
%         max(max(abs(kpp - smolyak(mu,xm,xs,S,x)*b)))
        kpp=permute(reshape(kpp,M,J,N),[1 3 2]);
    else
        kpp=nan(M,N,J);
t0=tic;
        for j=1:J
            kpp(:,:,j)=smolyak(mu,xm,xs,S,[kp ap(:,:,j)])*b;
        end
t1=t1+toc(t0);
    end
    ucp=repmat(mean(bsxfun(@plus,bsxfun(@times,A*kp.^alpha,ap)-kpp,(1-delta)*kp),2).^-gam,1,N,1);
    r=1-delta+bsxfun(@times,(A*alpha)*kp.^(alpha-1),ap);
    ucp=reshape(reshape(ucp.*r,M*N,J)*w,M,N);
    uc=mean(A*a.*k.^alpha+(1-delta)*k-kp,2).^-gam;
    y=bsxfun(@rdivide,ucp,uc/(bdamp*beta))+(1-bdamp);
    kp = y.*kp;
    b = B_inv*kp;
    if ~mod(it,disp_iter)
        dkp=mean(abs(1-y(:)));
        t2=t3; t3=toc; t2=t3-t2; gflops=L*M*(2*N+max(mu)-1)/t1*disp_iter/1e9;
        fprintf('it=%g \t gflops=%f \t kernel_time=%f (%.1f%%) \t run_time=%g \t diff=%e\n',it,gflops,t1,100*t1/t2,6500/it*t3,dkp)
        t1=0;
        if dkp<1e-10; break; end
    end
end
time_Smol = toc;
fprintf('N = %d\tmu = %d\ttime = %f\n',N,mu(1),time_Smol)
if gpu; b=gather(b); end
save(bfile,'b')

%% compute Euler equation errors
gpu=false;
tic
T_test=10200; discard=200; Omega=chol(Sigma);
if gssa
    load Smolyak_Anisotropic_JMMV_2014/aT20200N10
    T=10000; x = [ones(T_test,N) a20200(T+1:T+T_test,1:N); 1 nan(1,2*N-1)];
else
    x=ones(T_test+1,2*N); rng(1); E=exp(randn(T_test,N)*Omega);
end
for t=1:T_test
    x(t+1,1:N)=smolyak(mu,xm,xs,S,x(t,:))*b;
    if ~gssa
        x(t+1,N+1:2*N)=x(t,N+1:2*N).^rho.*E(t,:);
    end
end
x=x(1+discard:end,:);
T=T_test-discard;
k=x(1:T,1:N); kp=x(2:T+1,1:N); a=x(1:T,N+1:2*N);
ap=reshape(bsxfun(@times,repmat(a.^rho,1,J),e(:)'),T,N,J);
apn=reshape(permute(ap,[1 3 2]),T*J,N);
uc=mean(A*a.*k.^alpha+(1-delta)*k-kp,2).^-gam;
if gpu
%     if system(sprintf('nvcc -arch=sm_35 -ptx smolyak_kernel.cu -DD=%d -DL=%d -DM=%d -DN=%d -DSMAX=%d -DMU_MAX=%d',D,T*J,M,N,2^max(mu),max(mu))); error('nvcc failed'); end
    kernel = parallel.gpu.CUDAKernel('smolyak_kernel.ptx', 'smolyak_kernel.cu');
    kernel.ThreadBlockSize = 128;
    kernel.GridSize = ceil(T*J/kernel.ThreadBlockSize(1));
    setConstantMemory(kernel,'xm',xm);
    setConstantMemory(kernel,'xs',xs);
    setConstantMemory(kernel,'s',uint8(S-1));
    x=[repmat(kp,J,1) apn];
    kpp=nan(T*J,N,'gpuArray');
    kpp = gather(feval(kernel, x, kpp, b));
    kpp=permute(reshape(kpp,T,J,N),[1 3 2]);
else
    kpp=nan(T,N,J);
    for j=1:J
        kpp(:,:,j)=smolyak(mu,xm,xs,S,[kp ap(:,:,j)])*b;
    end
end
% max(max(abs(kpp-kpp_)),[],3)
ucp=repmat(mean(bsxfun(@plus,bsxfun(@times,A*kp.^alpha,ap)-kpp,(1-delta)*kp),2).^-gam,1,N,1);
r=1-delta+bsxfun(@times,(A*alpha)*kp.^(alpha-1),ap);
err=1-bsxfun(@rdivide,reshape(reshape(ucp.*r,T*N,J)*w,T,N),uc/beta); % Unit-free Euler-equation errors
err_mean=log10(mean(abs(err(:))));
err_max=log10(max(abs(err(:))));
time_test = toc;
%% Display the results
format short g
disp(' '); disp('           SMOLYAK OUTPUT:'); disp(' '); 
disp('RUNNING TIME (in seconds):'); disp('');
disp('a) for computing the solution'); 
disp(time_Smol);
disp('b) for implementing the accuracy test'); 
disp(time_test);
disp('APPROXIMATION ERRORS (log10):'); disp(''); 
disp('a) mean Euler-equation error'); 
disp(err_mean)
disp('b) max Euler-equation error'); 
disp(err_max)