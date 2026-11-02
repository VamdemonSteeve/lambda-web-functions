# Built for linux/arm64 (see scripts/build-and-push.sh) to match the webfn
# target's runtime (nodejs24.x) and CPU architecture (Arm64).
FROM node:24-slim

COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:0.9.1 /lambda-adapter /opt/extensions/lambda-adapter

WORKDIR /app

COPY app/package*.json ./
RUN npm install --omit=dev

COPY app/ ./

ENV PORT=8080
EXPOSE 8080

CMD ["node", "server.js"]
